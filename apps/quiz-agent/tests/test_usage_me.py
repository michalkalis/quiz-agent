"""GET /usage/me — bearer-derived identity for the freemium read path (#96 P1).

Every write path (session create, RC webhook grants, /entitlements/sync) keys
paid state on the bearer subject. The old ``GET /usage/{user_id}`` read whatever
id the client put in the path — the iOS app passed its local deviceId, so
purchases could never show up as paid. These pin that (a) the read path derives
the subject from the bearer exactly like the write paths, (b) an anonymous call
is rejected, and (c) the client-suppliable path-param variant stays deleted.
"""

from __future__ import annotations

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from fastapi import FastAPI
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.api.routes import misc as misc_routes
from app.auth.tokens import TokenService
from app.rate_limit import limiter
from app.usage.tracker import UsageTracker

pytestmark = pytest.mark.asyncio

_SECRET = "t" * 64
_SUBJECT = "anon-usage-me-subject"


def _token_service() -> TokenService:
    return TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )


def _bearer(subject: str = _SUBJECT) -> dict[str, str]:
    return {"Authorization": f"Bearer {_token_service().create_access_token(subject)}"}


@pytest_asyncio.fixture
async def client(db_sessionmaker, monkeypatch):
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(misc_routes.router, prefix="/api/v1")
    app.state.token_service = _token_service()
    app.state.usage_tracker = UsageTracker(db_sessionmaker, monthly_limit=3)
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def test_usage_me_returns_bearer_subject(client):
    """The reported usage belongs to the token subject — the client cannot
    ask about (or accidentally read) any other identity."""
    resp = await client.get("/api/v1/usage/me", headers=_bearer())
    assert resp.status_code == 200
    body = resp.json()
    assert body["user_id"] == _SUBJECT
    assert body["questions_limit"] == 3


async def test_usage_me_reflects_recorded_usage(client):
    """A question recorded under the subject shows up for the same bearer —
    the read and write paths agree on identity (the P1 defect was that they
    did not)."""
    tracker = None
    # Reach the tracker through the app the client wraps.
    tracker = client._transport.app.state.usage_tracker  # noqa: SLF001
    await tracker.record_question(_SUBJECT)
    resp = await client.get("/api/v1/usage/me", headers=_bearer())
    assert resp.status_code == 200
    assert resp.json()["questions_used"] == 1


async def test_usage_me_rejects_anonymous(client):
    resp = await client.get("/api/v1/usage/me")
    assert resp.status_code == 401


async def test_usage_path_param_variant_stays_deleted(client):
    """Regression guard: a client-suppliable /usage/{id} GET must not come
    back — it reintroduces the identity split."""
    resp = await client.get(f"/api/v1/usage/{_SUBJECT}", headers=_bearer())
    assert resp.status_code in (404, 405)
