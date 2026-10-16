"""Dictation transcription route (#208.8).

Why it exists: the founder moved every speech-to-text call to OpenAI
gpt-transcribe (2026-10-16), so the feedback / rating / pack-prompt dictation
can no longer stream to ElevenLabs. The app records the clip and sends it here.
What must hold:

- the player's language reaches the recogniser as a hint (sk/cs dictation
  transcribed as English is useless);
- it is a paid STT call, so it needs a verified account and counts against
  the same daily STT seconds cap as answers, refused BEFORE the paid call;
- a recogniser hallucination on silence never lands in the player's text.
"""

from __future__ import annotations

from unittest.mock import AsyncMock

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from app.api import deps
from app.api.routes import dictation as dictation_routes
from app.auth.identity import AuthSubject
from app.rate_limit import limiter
from app.usage.caps import UsageCaps
from app.voice.transcriber import TranscriptionResult, VoiceTranscriber

from tests.test_daily_caps import _assert_plain_429, _wav

pytestmark = pytest.mark.asyncio

URL = "/api/v1/voice/dictation"


def _result(text: str) -> TranscriptionResult:
    return TranscriptionResult(
        text=text, language=None, no_speech_prob=0.0, avg_logprob=0.0, duration=0.0
    )


def _app(
    transcriber: VoiceTranscriber,
    *,
    caps: UsageCaps | None = None,
    authenticated: bool = True,
) -> FastAPI:
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.include_router(dictation_routes.router, prefix="/api/v1")
    app.dependency_overrides[deps.require_auth_or_grace] = lambda: AuthSubject(
        subject_id="u_dict" if authenticated else None,
        is_legacy=not authenticated,
        authenticated=authenticated,
    )
    app.dependency_overrides[deps.get_voice_transcriber] = lambda: transcriber
    app.dependency_overrides[deps.get_usage_caps] = lambda: caps or UsageCaps(None)
    return app


def _transcriber(text: str = "Otázka o Váhu mala zlú odpoveď") -> VoiceTranscriber:
    t = VoiceTranscriber.__new__(VoiceTranscriber)  # no OpenAI client needed
    t.language = None
    t.transcribe = AsyncMock(return_value=_result(text))
    return t


async def _post(app: FastAPI, audio: bytes, filename="dictation.wav", **form):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        return await c.post(
            URL, files={"audio": (filename, audio, "audio/wav")}, data=form
        )


async def test_text_comes_back_and_the_language_hint_reaches_the_recogniser():
    t = _transcriber()
    resp = await _post(_app(t), _wav(3), language="sk")

    assert resp.status_code == 200
    assert resp.json() == {"text": "Otázka o Váhu mala zlú odpoveď"}
    assert t.transcribe.await_args.kwargs["language"] == "sk"
    # Free-form text: no quiz prompt may steer it toward an answer.
    assert t.transcribe.await_args.kwargs.get("prompt") is None


async def test_a_hallucination_on_silence_comes_back_empty():
    resp = await _post(_app(_transcriber("Thank you.")), _wav(2), language="en")
    assert resp.status_code == 200
    assert resp.json() == {"text": ""}


async def test_an_unverified_caller_is_refused_before_stt():
    """Without a verified account the daily cap has nobody to count."""
    t = _transcriber()
    resp = await _post(_app(t, authenticated=False), _wav(2))
    assert resp.status_code == 401
    t.transcribe.assert_not_awaited()


async def test_an_unsupported_format_is_refused_before_stt():
    t = _transcriber()
    resp = await _post(_app(t), b"not audio", filename="clip.txt")
    assert resp.status_code == 400
    t.transcribe.assert_not_awaited()


async def test_a_malformed_language_is_refused_before_stt():
    t = _transcriber()
    resp = await _post(_app(t), _wav(2), language="slovak; drop")
    assert resp.status_code == 422
    t.transcribe.assert_not_awaited()


async def test_an_oversized_clip_is_a_400_not_a_500():
    """The recogniser's own size check is a client fault, not a server error."""
    t = VoiceTranscriber.__new__(VoiceTranscriber)
    t.language = None
    t.model = "gpt-transcribe"
    t._transcribe_retrying = AsyncMock()
    big = b"\0" * (VoiceTranscriber.MAX_FILE_SIZE + 1)
    resp = await _post(_app(t), big)
    assert resp.status_code == 400
    t._transcribe_retrying.assert_not_awaited()


async def test_a_provider_failure_is_a_502_without_internals():
    t = _transcriber()
    t.transcribe = AsyncMock(side_effect=RuntimeError("Transcription failed: key sk-…"))
    resp = await _post(_app(t), _wav(2))
    assert resp.status_code == 502
    assert "sk-" not in resp.text


async def test_dictation_shares_the_daily_stt_seconds_cap(db_sessionmaker, monkeypatch):
    """Dictation and answers draw on ONE per-account STT budget; over it the
    refusal comes before the paid call and is the plain cap 429."""
    monkeypatch.setenv("DAILY_CAP_STT_SECONDS", "20")
    t = _transcriber()
    app = _app(t, caps=UsageCaps(db_sessionmaker))

    assert (await _post(app, _wav(12))).status_code == 200  # 12 s
    assert (await _post(app, _wav(12))).status_code == 200  # 24 s, crossed
    resp = await _post(app, _wav(12))

    _assert_plain_429(resp)
    assert resp.json()["detail"]["cap"] == "stt_seconds"
    assert t.transcribe.await_count == 2
