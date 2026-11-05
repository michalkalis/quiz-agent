"""An exhausted OpenAI credit must reach the founder, not just the logs.

2026-11-04: the prepaid OpenAI credit ran out. Every answer transcription
(gpt-transcribe) and the TTS fallback then failed with 429
``insufficient_quota`` while the App Store build was live, and nothing alerted:
the balance check compares spend with a budget and cannot see a prepaid
balance. Pinned here:
- a 429 whose code says the credit is gone, and a 401/403 (bad key), raise a
  Sentry error (Sentry e-mails the founder) — from both the STT and TTS path;
- an ordinary 429 rate limit and a 5xx stay silent: they heal on their own and
  an alert per busy minute would bury the real one;
- one alert per service+reason per hour, so an outage is one issue.
"""

from __future__ import annotations

import io
from contextlib import contextmanager
from types import SimpleNamespace

import httpx
import openai
import pytest
from app.monitoring import provider_alerts
from app.tts.providers import OpenAITTSProvider
from app.voice.transcriber import VoiceTranscriber

NO_CREDIT = {
    "message": "You have no credits remaining. Add credits to continue using the API.",
    "type": "insufficient_quota",
    "code": "credit_balance_exhausted",
}


class _Sentry:
    def __init__(self):
        self.alerts: list[dict] = []
        self._scope = None

    @contextmanager
    def new_scope(self):
        self._scope = SimpleNamespace(
            fingerprint=None,
            tags={},
            contexts={},
            set_tag=lambda k, v: self._scope.tags.__setitem__(k, v),
            set_context=lambda k, v: self._scope.contexts.__setitem__(k, v),
        )
        yield self._scope

    def capture_message(self, message, level=None):
        self.alerts.append(
            {
                "message": message,
                "level": level,
                "fingerprint": self._scope.fingerprint,
                "tags": dict(self._scope.tags),
                "contexts": dict(self._scope.contexts),
            }
        )


@pytest.fixture
def sentry(monkeypatch):
    fake = _Sentry()
    monkeypatch.setattr(provider_alerts, "sentry_sdk", fake)
    provider_alerts._last_alert_at.clear()
    yield fake
    provider_alerts._last_alert_at.clear()


def _status_error(cls, status: int, body: dict | None):
    request = httpx.Request("POST", "https://api.openai.com/v1/audio/transcriptions")
    response = httpx.Response(status, request=request, json={"error": body or {}})
    return cls("refused", response=response, body=body)


def test_exhausted_credit_alerts_with_openai_reason(sentry):
    provider_alerts.report_openai_refusal(
        "stt", _status_error(openai.RateLimitError, 429, NO_CREDIT)
    )
    assert len(sentry.alerts) == 1
    alert = sentry.alerts[0]
    assert alert["level"] == "error"
    assert "credit_balance_exhausted" in alert["message"]
    assert alert["fingerprint"] == ["openai-refused", "stt", "credit_balance_exhausted"]
    assert "no credits remaining" in alert["contexts"]["openai"]["message"]


def test_bad_key_alerts(sentry):
    provider_alerts.report_openai_refusal(
        "tts",
        _status_error(openai.AuthenticationError, 401, {"code": "invalid_api_key"}),
    )
    assert [a["tags"]["openai_reason"] for a in sentry.alerts] == ["invalid_api_key"]


@pytest.mark.parametrize(
    "cls,status,body",
    [
        (
            openai.RateLimitError,
            429,
            {"code": "rate_limit_exceeded", "type": "requests"},
        ),
        (openai.InternalServerError, 500, {"type": "server_error"}),
    ],
)
def test_transient_failures_stay_silent(sentry, cls, status, body):
    provider_alerts.report_openai_refusal("stt", _status_error(cls, status, body))
    assert sentry.alerts == []


def test_outage_is_one_alert_per_hour(sentry):
    for _ in range(5):
        provider_alerts.report_openai_refusal(
            "stt", _status_error(openai.RateLimitError, 429, NO_CREDIT)
        )
    assert len(sentry.alerts) == 1


@pytest.mark.asyncio
async def test_transcription_refusal_alerts_and_still_raises(sentry):
    """The live answer path: the player still gets the existing error handling."""
    transcriber = VoiceTranscriber.__new__(VoiceTranscriber)
    transcriber.model = "gpt-transcribe"

    async def _refuse(**_):
        raise _status_error(openai.RateLimitError, 429, NO_CREDIT)

    transcriber.client = SimpleNamespace(
        audio=SimpleNamespace(transcriptions=SimpleNamespace(create=_refuse))
    )
    with pytest.raises(openai.RateLimitError):
        await transcriber._transcribe_openai(
            audio_file=io.BytesIO(b"audio"),
            filename="a.m4a",
            prompt=None,
            language="sk",
        )
    assert [a["tags"]["openai_service"] for a in sentry.alerts] == ["stt"]


@pytest.mark.asyncio
async def test_tts_fallback_refusal_alerts_and_still_raises(sentry):
    provider = OpenAITTSProvider.__new__(OpenAITTSProvider)
    provider.model = "tts-1"

    async def _refuse(**_):
        raise _status_error(openai.RateLimitError, 429, NO_CREDIT)

    provider.client = SimpleNamespace(
        audio=SimpleNamespace(speech=SimpleNamespace(create=_refuse))
    )
    with pytest.raises(openai.RateLimitError):
        await provider.synthesize("Ahoj", "alloy")
    assert [a["tags"]["openai_service"] for a in sentry.alerts] == ["tts"]
