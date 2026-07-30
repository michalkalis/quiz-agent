"""#91 follow-up: game/voice/TTS routes must not echo exception text to clients.

The 2026-07-07 auth review (item 4) fixed sessions.py/quiz.py 500s that
returned ``str(e)`` in the HTTP detail; voice.py, tts.py and misc.py had the
same defect class — worse, with zero server-side logging. These tests pin the
log-then-generic contract: internal exception text never reaches the response
body, while deliberately constructed validation 400s (format/size/empty-text)
keep their client-facing messages. Also pins that an HTTPException raised
inside the try block passes through instead of being swallowed into a 500
(latent bug found in the same sweep).
"""

from __future__ import annotations

import asyncio
from unittest.mock import MagicMock

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from fastapi import FastAPI
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.api import deps
from app.api.routes import misc as misc_routes
from app.api.routes import tts as tts_routes
from app.api.routes import voice as voice_routes
from app.auth.identity import AuthSubject
from app.rate_limit import limiter
from app.voice.transcriber import VoiceTranscriber
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

pytestmark = pytest.mark.asyncio

SECRET = "SECRET_INTERNAL_DETAIL_pg_dsn=postgres://user:pw@host/db"

_SESSION_ID = "s_leak"
_QUESTION_ID = "q_leak"


class _ExplodingTranscriber:
    SUPPORTED_FORMATS = VoiceTranscriber.SUPPORTED_FORMATS

    def __init__(self, supported: bool = True):
        self._supported = supported

    def is_supported_format(self, filename):
        return self._supported

    async def transcribe_with_quiz_context(self, **kwargs):
        raise RuntimeError(SECRET)


class _StubSessionManager:
    """Just enough SessionManager for the /voice/submit route to reach the body."""

    def __init__(self):
        self._session = QuizSession(
            session_id=_SESSION_ID,
            phase=SessionPhase.ASKING,
            current_question_id=_QUESTION_ID,
            asked_question_ids=[_QUESTION_ID],
        )
        self._lock = asyncio.Lock()

    def get_session(self, session_id: str) -> QuizSession:
        return self._session

    def update_session(self, session: QuizSession) -> bool:
        return True

    def session_lock(self, session_id: str) -> asyncio.Lock:
        return self._lock


class _ExplodingTTS:
    def __init__(self, exc: Exception):
        self._exc = exc

    async def synthesize(self, *args, **kwargs):
        raise self._exc


def _app() -> FastAPI:
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    for router in (voice_routes.router, tts_routes.router, misc_routes.router):
        app.include_router(router, prefix="/api/v1")
    app.dependency_overrides[deps.require_auth_or_grace] = lambda: AuthSubject(
        subject_id="test-subject", is_legacy=False, authenticated=True
    )
    return app


def _voice_submit_app(transcriber: _ExplodingTranscriber) -> FastAPI:
    """``/voice/submit`` wired to reach its try block: real route, stub collaborators."""
    app = _app()
    retriever = MagicMock()
    retriever.get = MagicMock(
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
    flow = MagicMock()
    flow.classify_submission = MagicMock(return_value=False)
    app.dependency_overrides[deps.get_session_manager] = _StubSessionManager
    app.dependency_overrides[deps.get_question_retriever] = lambda: retriever
    app.dependency_overrides[deps.get_quiz_flow] = lambda: flow
    app.dependency_overrides[deps.get_voice_transcriber] = lambda: transcriber
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


_AUDIO = {"audio": ("answer.mp3", b"fake-bytes", "audio/mpeg")}


async def test_voice_submit_500_hides_exception_text(make_client):
    # #133 V6a removed the standalone /voice/transcribe (unused, billed a Whisper
    # call per request); /voice/submit is the only transcription entry point left
    # and carries the same log-then-generic contract.
    client = await make_client(_voice_submit_app(_ExplodingTranscriber()))

    resp = await client.post(f"/api/v1/voice/submit/{_SESSION_ID}", files=_AUDIO)

    assert resp.status_code == 500
    assert resp.json()["detail"] == "Voice submission failed"
    assert SECRET not in resp.text


async def test_voice_submit_unsupported_format_stays_400(make_client):
    # Regression: the explicit 400 raised inside the try block used to be
    # swallowed by ``except Exception`` and returned as a 500.
    client = await make_client(
        _voice_submit_app(_ExplodingTranscriber(supported=False))
    )

    resp = await client.post(f"/api/v1/voice/submit/{_SESSION_ID}", files=_AUDIO)

    assert resp.status_code == 400
    assert "Unsupported audio format" in resp.json()["detail"]


async def test_tts_synthesize_500_hides_exception_text(make_client):
    app = _app()
    app.dependency_overrides[deps.get_tts_service] = lambda: _ExplodingTTS(
        RuntimeError(SECRET)
    )
    client = await make_client(app)

    resp = await client.post(
        "/api/v1/tts/synthesize", json={"text": "hello", "voice": "nova"}
    )

    assert resp.status_code == 500
    assert resp.json()["detail"] == "TTS synthesis failed"
    assert SECRET not in resp.text


async def test_tts_synthesize_validation_400_keeps_message(make_client):
    # Constructed validation text is the intended client contract — must survive.
    app = _app()
    app.dependency_overrides[deps.get_tts_service] = lambda: _ExplodingTTS(
        ValueError("Text cannot be empty")
    )
    client = await make_client(app)

    resp = await client.post(
        "/api/v1/tts/synthesize", json={"text": " ", "voice": "nova"}
    )

    assert resp.status_code == 400
    assert resp.json()["detail"] == "Text cannot be empty"


async def test_elevenlabs_token_502_hides_exception_text(make_client, monkeypatch):
    monkeypatch.setenv("ELEVENLABS_API_KEY", "test-key")

    class _ExplodingAsyncClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        async def post(self, *args, **kwargs):
            raise ConnectionError(SECRET)

    monkeypatch.setattr("httpx.AsyncClient", _ExplodingAsyncClient)
    client = await make_client(_app())

    resp = await client.post("/api/v1/elevenlabs/token")

    assert resp.status_code == 502
    assert resp.json()["detail"] == "Failed to get ElevenLabs token"
    assert SECRET not in resp.text
