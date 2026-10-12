"""#200: an ElevenLabs quota/auth refusal must reach the founder, not just the logs.

TF test 2026-10-12: the API key hit its own 10,000-credit cap. ElevenLabs then
answered every TTS and STT call with 401 ``quota_exceeded``, the OpenAI
fallbacks took over, the quiz kept working — and nobody noticed until the
founder heard the fallback voice mangle Slovak years. The daily balance check
reads the account quota (which still had credit), so it stayed green.

Pinned here, for both TTS and STT:
- a 401/402/403 refusal raises a Sentry error (Sentry emails the founder) with
  ElevenLabs' own reason, while the fallback still serves the player;
- the alert is rate-limited per service+reason (one per hour), so an outage is
  one alert, not one per question;
- transient failures (5xx) stay log-only — the fallback covers them.
"""

from __future__ import annotations

from contextlib import contextmanager
from types import SimpleNamespace

import httpx
import pytest
from httpx import MockTransport, Response

from app.monitoring import provider_alerts
from app.tts.providers import ElevenLabsTTSProvider
from app.tts.service import TTSService
from app.voice.scribe import ScribeBatchTranscriber, ScribeUnavailable

pytestmark = pytest.mark.asyncio

QUOTA_BODY = {
    "detail": {
        "status": "quota_exceeded",
        "message": "This request exceeds your API key quota of 10000. "
        "You have 51 credits remaining, while 120 credits are required.",
    }
}


class _Sentry:
    """Stands in for sentry_sdk: records each alert with its scope."""

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


class _Clock:
    def __init__(self):
        self.now = 1000.0

    def monotonic(self):
        return self.now


@pytest.fixture
def sentry(monkeypatch):
    fake = _Sentry()
    monkeypatch.setattr(provider_alerts, "sentry_sdk", fake)
    monkeypatch.setattr(provider_alerts, "_last_alert_at", {})
    return fake


@pytest.fixture
def clock(monkeypatch):
    fake = _Clock()
    monkeypatch.setattr(provider_alerts, "time", fake)
    return fake


@pytest.fixture(autouse=True)
def _env(tmp_path, monkeypatch):
    monkeypatch.setenv("TTS_CACHE_DIR", str(tmp_path / "tts_cache"))
    monkeypatch.setenv("ELEVENLABS_API_KEY", "test-key")


def _route_elevenlabs(monkeypatch, status: int, body: dict):
    def handler(request: httpx.Request) -> Response:
        return Response(status, json=body)

    transport = MockTransport(handler)
    real_init = httpx.AsyncClient.__init__

    def patched_init(self, *args, **kwargs):
        kwargs["transport"] = transport
        real_init(self, *args, **kwargs)

    monkeypatch.setattr(httpx.AsyncClient, "__init__", patched_init)


class _Backup:
    name = "openai"
    default_voice = "nova"

    async def synthesize(self, text: str, voice: str) -> bytes:
        return b"backup-audio"


def _tts() -> TTSService:
    return TTSService(provider=ElevenLabsTTSProvider(), fallback_provider=_Backup())


async def test_tts_quota_refusal_alerts_while_the_backup_voice_plays(
    monkeypatch, sentry, clock
):
    _route_elevenlabs(monkeypatch, 401, QUOTA_BODY)

    audio = await _tts().synthesize("V roku 1918 vzniklo Československo.")

    assert audio == b"backup-audio"  # the player still hears the question
    assert len(sentry.alerts) == 1
    alert = sentry.alerts[0]
    assert alert["level"] == "error"
    assert alert["fingerprint"] == ["elevenlabs-refused", "tts", "quota_exceeded"]
    # ElevenLabs' own explanation travels with it: it names the KEY's cap.
    assert "API key quota of 10000" in alert["contexts"]["elevenlabs"]["message"]


async def test_one_alert_per_hour_not_one_per_question(monkeypatch, sentry, clock):
    _route_elevenlabs(monkeypatch, 401, QUOTA_BODY)
    service = _tts()

    for i in range(5):
        await service.synthesize(f"Otázka číslo {i}?")
    assert len(sentry.alerts) == 1

    clock.now += provider_alerts.ALERT_INTERVAL_S + 1
    await service.synthesize("Ďalšia otázka?")
    assert len(sentry.alerts) == 2  # still broken an hour later → reminded


async def test_stt_quota_refusal_alerts_separately_from_tts(monkeypatch, sentry, clock):
    _route_elevenlabs(monkeypatch, 401, QUOTA_BODY)

    with pytest.raises(ScribeUnavailable):
        await ScribeBatchTranscriber().transcribe(b"audio", "answer.m4a")

    assert [a["fingerprint"] for a in sentry.alerts] == [
        ["elevenlabs-refused", "stt", "quota_exceeded"]
    ]


@pytest.mark.parametrize(
    "status,body,reason",
    [
        (401, {"detail": {"status": "invalid_api_key", "message": "bad key"}}, None),
        (402, {"detail": "payment required"}, "http_402"),
    ],
)
async def test_auth_and_payment_refusals_alert_with_their_reason(
    monkeypatch, sentry, clock, status, body, reason
):
    _route_elevenlabs(monkeypatch, status, body)

    await _tts().synthesize("Otázka?")

    expected = reason or body["detail"]["status"]
    assert sentry.alerts[0]["fingerprint"][-1] == expected


async def test_a_transient_outage_does_not_page_anyone(monkeypatch, sentry, clock):
    _route_elevenlabs(monkeypatch, 503, {"detail": "busy"})

    assert await _tts().synthesize("Otázka?") == b"backup-audio"
    with pytest.raises(ScribeUnavailable):
        await ScribeBatchTranscriber().transcribe(b"audio", "answer.m4a")

    assert sentry.alerts == []
