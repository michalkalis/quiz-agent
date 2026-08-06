"""#148: one flow, one error contract — /input and /voice/submit must agree.

Both submit routes run over the same ``QuizFlowService.process_answer``, but
their error handling had drifted (arch audit 2026-08-06): a missing question row
— a server-side data fault — paged as a 500 with a Sentry capture on the text
route while the voice route's bare ``except ValueError`` handed the player a 400
with the raw internal message, telling them their *input* was bad. The mirror
half was worse: the retryable 503 envelope existed only on the text route, and
``TransientRetry.isTransient`` on iOS passes only 502/503 — so a cold-wake DB
blip during a voice submit could never engage the client retry that #131 Track A
shipped for exactly that failure.

These tests are parametrized over both routes on purpose: the assertion is not
"this route returns 503", it is "the same condition returns the same thing on
both". A future route that maps an untyped exception itself fails here.
"""

from __future__ import annotations

import asyncio
from typing import Callable
from unittest.mock import AsyncMock, MagicMock

import pytest
import pytest_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from sqlalchemy.exc import OperationalError

from app.api import deps, submit_errors
from app.api.routes import quiz as quiz_routes
from app.api.routes import voice as voice_routes
from app.auth.identity import AuthSubject
from app.quiz.errors import InvalidSubmission, QuestionMismatch, QuestionUnavailable
from app.rate_limit import limiter
from app.voice.transcriber import VoiceTranscriber
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

pytestmark = pytest.mark.asyncio

_SESSION_ID = "s_contract"
_QUESTION_ID = "q_contract"
_SUBJECT = "u_contract"
_AUDIO_FILE = {"audio": ("answer.mp3", b"fake-bytes", "audio/mpeg")}


def _session() -> QuizSession:
    return QuizSession(
        session_id=_SESSION_ID,
        user_id=_SUBJECT,
        phase=SessionPhase.ASKING,
        current_question_id=_QUESTION_ID,
        asked_question_ids=[_QUESTION_ID],
        max_questions=10,
    )


class _StubSessionManager:
    """Enough SessionManager for either submit route to reach its try block."""

    def __init__(self):
        self._session = _session()
        self._lock = asyncio.Lock()

    def get_session(self, session_id: str) -> QuizSession:
        return self._session

    def update_session(self, session: QuizSession) -> bool:
        return True

    def session_lock(self, session_id: str) -> asyncio.Lock:
        return self._lock


class _Transcription:
    text = "Paris"
    no_speech_prob = 0.01
    avg_logprob = -0.1

    def is_valid(self) -> bool:
        return True

    def get_rejection_reason(self) -> str:  # pragma: no cover - never rejected here
        return ""


class _Transcriber:
    """A transcriber that succeeds, so the voice route reaches the shared flow."""

    SUPPORTED_FORMATS = VoiceTranscriber.SUPPORTED_FORMATS

    def __init__(self, *, supported: bool = True, transcribe_error: Exception = None):
        self._supported = supported
        self._error = transcribe_error

    def is_supported_format(self, filename) -> bool:
        return self._supported

    async def transcribe_with_quiz_context(self, **kwargs):
        if self._error:
            raise self._error
        return _Transcription()


def _base_app() -> FastAPI:
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(quiz_routes.router, prefix="/api/v1")
    app.include_router(voice_routes.router, prefix="/api/v1")
    app.dependency_overrides[deps.require_auth_or_grace] = lambda: AuthSubject(
        subject_id=_SUBJECT, is_legacy=False, authenticated=True
    )
    app.dependency_overrides[deps.get_session_manager] = _StubSessionManager
    return app


def _app(
    *,
    process_answer_error: Exception | None = None,
    transcriber: _Transcriber | None = None,
) -> FastAPI:
    app = _base_app()

    retriever = MagicMock()
    retriever.get = AsyncMock(
        return_value=Question(
            id=_QUESTION_ID,
            question="What is the capital of France?",
            type="text",
            correct_answer="Paris",
            topic="Geography",
            category="general",
            difficulty="medium",
        )
    )
    retriever.get_next_question = AsyncMock(return_value=None)
    app.dependency_overrides[deps.get_question_retriever] = lambda: retriever

    flow = MagicMock()
    flow.classify_submission = MagicMock(return_value=False)
    flow.process_answer = AsyncMock(side_effect=process_answer_error)
    app.dependency_overrides[deps.get_quiz_flow] = lambda: flow

    app.dependency_overrides[deps.get_voice_transcriber] = lambda: (
        transcriber or _Transcriber()
    )
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


async def _post_text(client: AsyncClient):
    return await client.post(
        f"/api/v1/sessions/{_SESSION_ID}/input", json={"input": "Paris"}
    )


async def _post_voice(client: AsyncClient):
    return await client.post(f"/api/v1/voice/submit/{_SESSION_ID}", files=_AUDIO_FILE)


# Both submit surfaces, addressed identically. ids name the route in failures.
ROUTES: list[tuple[str, Callable]] = [("text", _post_text), ("voice", _post_voice)]
ROUTE_IDS = ["/input", "/voice-submit"]


@pytest.fixture
def sentry_captures(monkeypatch) -> list[Exception]:
    """Records what the shared mapping reports, on whichever route raised."""
    captured: list[Exception] = []
    monkeypatch.setattr(
        submit_errors.sentry_sdk,
        "get_client",
        lambda: MagicMock(is_active=lambda: True),
    )
    monkeypatch.setattr(
        submit_errors.sentry_sdk, "capture_exception", lambda e: captured.append(e)
    )
    return captured


@pytest.mark.parametrize("_name,post", ROUTES, ids=ROUTE_IDS)
async def test_missing_question_pages_identically_on_both_routes(
    make_client, sentry_captures, _name, post
):
    """A question row the flow cannot load is a SERVER fault. Telling the voice
    player "your input was bad" (the old 400) both blamed them for a backend bug
    and hid the fault from Sentry, so nothing ever alerted on it."""
    boom = QuestionUnavailable(_QUESTION_ID, stage="current")
    client = await make_client(_app(process_answer_error=boom))

    resp = await post(client)

    assert resp.status_code == 500
    assert sentry_captures == [boom]
    # The internal message (ids, stage) never reaches the client.
    assert _QUESTION_ID not in resp.text


@pytest.mark.parametrize("_name,post", ROUTES, ids=ROUTE_IDS)
async def test_transient_db_error_is_a_retryable_503_on_both_routes(
    make_client, sentry_captures, _name, post
):
    """The cold-wake envelope iOS retries on. ``TransientRetry.isTransient``
    passes only 502/503, so anything else here means a voice submit loses the
    player's answer to a hiccup the client could have ridden out
    (SubmitRetryTests: "voice submit survives a single cold-wake 503")."""
    client = await make_client(
        _app(
            process_answer_error=OperationalError(
                "connect", {}, Exception("connection refused")
            )
        )
    )

    resp = await post(client)

    assert resp.status_code == 503
    assert "retry" in resp.json()["detail"].lower()
    # A hiccup is not a bug: it must not page.
    assert sentry_captures == []


@pytest.mark.parametrize("_name,post", ROUTES, ids=ROUTE_IDS)
async def test_question_mismatch_stays_409_with_the_resync_id(make_client, _name, post):
    """#133 1a contract the clients already depend on — unchanged by #148."""
    client = await make_client(_app(process_answer_error=QuestionMismatch("q_current")))

    resp = await post(client)

    assert resp.status_code == 409
    assert resp.json()["detail"] == {
        "code": "question_mismatch",
        "current_question_id": "q_current",
    }


@pytest.mark.parametrize("_name,post", ROUTES, ids=ROUTE_IDS)
async def test_an_untyped_exception_is_never_a_client_error(
    make_client, sentry_captures, _name, post
):
    """The regression this issue exists for: voice.py caught bare ``ValueError``
    and returned it as a 400 with the raw message. An exception the flow did not
    classify is a bug — it pages on both routes, and its text stays server-side."""
    boom = ValueError("secret_internal_detail_should_not_leak")
    client = await make_client(_app(process_answer_error=boom))

    resp = await post(client)

    assert resp.status_code == 500
    assert "secret_internal_detail_should_not_leak" not in resp.text
    assert sentry_captures == [boom]


async def test_voice_rejects_an_oversized_upload_with_a_400(make_client):
    """The catch that *was* justified: format/size text is constructed
    server-side and is the client's actual problem. Typing it (InvalidSubmission)
    keeps the 400 without also swallowing every server fault that shares the
    ValueError type. (Format rejection: test_route_error_detail_leaks.py.)"""
    too_big = InvalidSubmission("File too large: 30.0 MB. Maximum: 25.0 MB")
    client = await make_client(_app(transcriber=_Transcriber(transcribe_error=too_big)))

    resp = await _post_voice(client)

    assert resp.status_code == 400
    assert resp.json()["detail"] == "File too large: 30.0 MB. Maximum: 25.0 MB"
