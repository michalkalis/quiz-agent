"""#131 Track A: POST /sessions/{id}/input must distinguish a transient infra
hiccup from a real bug.

Founder hit "Couldn't submit your answer" on staging (Fly `auto_stop_machines`
cold wake); Sentry showed a raw HTTP 500 on submit AND skip because
``quiz_flow.process_answer`` (which wraps the DB-backed usage-quota check) had
no exception wrapping at all. A raw 500 looks identical to a real bug to the
client, so nothing could distinguish "retry me" from "stop and report".

These tests pin: a DB connection/pool error (the cold-wake/pool-exhaustion
shape) comes back as a retryable 503, while an unexpected exception still
surfaces loudly — 500, logged, and captured in Sentry — instead of being
silently downgraded to "just retry".
"""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest
import pytest_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from sqlalchemy.exc import OperationalError
from sqlalchemy.exc import TimeoutError as SATimeoutError

from app.api import deps
from app.api.routes import quiz as quiz_routes
from app.rate_limit import limiter
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.session import QuizSession

pytestmark = pytest.mark.asyncio

_SESSION_ID = "s_transient_test"


def _session() -> QuizSession:
    return QuizSession(
        session_id=_SESSION_ID,
        user_id="u_1",
        phase=SessionPhase.ASKING,
        current_question_id="q_1",
        asked_question_ids=["q_1"],
        max_questions=10,
    )


def _app(process_answer_side_effect: Exception) -> FastAPI:
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(quiz_routes.router, prefix="/api/v1")

    session_manager = MagicMock()
    session_manager.get_session = MagicMock(return_value=_session())
    app.dependency_overrides[deps.get_session_manager] = lambda: session_manager

    quiz_flow = MagicMock()
    quiz_flow.process_answer = AsyncMock(side_effect=process_answer_side_effect)
    app.dependency_overrides[deps.get_quiz_flow] = lambda: quiz_flow

    return app


@pytest_asyncio.fixture
async def make_client():
    limiter.reset()
    clients = []

    async def _make(app: FastAPI) -> AsyncClient:
        c = AsyncClient(transport=ASGITransport(app=app), base_url="http://test")
        clients.append(c)
        return c

    yield _make
    for c in clients:
        await c.aclose()


@pytest.mark.parametrize(
    "exc",
    [
        OperationalError("connect", {}, Exception("connection refused")),
        SATimeoutError("QueuePool limit of size 5 overflow 10 reached"),
        ConnectionError("connection reset"),
        TimeoutError("pool checkout timed out"),
    ],
    ids=["OperationalError", "pool-TimeoutError", "ConnectionError", "TimeoutError"],
)
async def test_transient_infra_error_returns_retryable_503(make_client, exc):
    """A cold-wake DB error (disconnect, pool exhaustion, socket timeout) must
    come back as a distinguishable, retryable 503 — not a raw 500 that reads
    identically to a real bug on the client."""
    app = _app(exc)
    client = await make_client(app)

    resp = await client.post(
        f"/api/v1/sessions/{_SESSION_ID}/input", json={"input": "Paris"}
    )

    assert resp.status_code == 503
    assert "retry" in resp.json()["detail"].lower()


async def test_unexpected_error_still_surfaces_as_500_and_is_captured(
    make_client, monkeypatch
):
    """A genuine bug (anything outside the transient-infra set) must NOT be
    silently downgraded to a retryable response — it stays a 500 and is
    reported to Sentry, matching the existing log+capture convention
    elsewhere in the app (feedback.py)."""
    captured: list[Exception] = []
    monkeypatch.setattr(
        quiz_routes.sentry_sdk,
        "get_client",
        lambda: MagicMock(is_active=lambda: True),
    )
    monkeypatch.setattr(
        quiz_routes.sentry_sdk, "capture_exception", lambda e: captured.append(e)
    )

    boom = RuntimeError("secret_internal_detail_should_not_leak")
    app = _app(boom)
    client = await make_client(app)

    resp = await client.post(
        f"/api/v1/sessions/{_SESSION_ID}/input", json={"input": "Paris"}
    )

    assert resp.status_code == 500
    assert resp.json()["detail"] == "Failed to process your answer"
    assert "secret_internal_detail_should_not_leak" not in resp.text
    assert captured == [boom]
