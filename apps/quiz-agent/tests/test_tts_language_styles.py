"""Faster question voice per language (founder 2026-11-18).

The founder listened to George on Flash v2.5 and decided: "v appke en 1,1x a
sk/cz 1,07x". v4 Turbo ignores `speed`, so each language may name its own
model, and Flash must be told sk/cs or it guesses the language from the text.
What breaks silently without these tests:

- the cache key ignoring model/speed: every player keeps hearing the old,
  slower clip and the change appears to do nothing;
- Ukrainian drifting off v3 + stability 1.0, which a native speaker chose;
- the speed living in code: rollback must stay a config change that brings
  the old clips back without paying for them again.
"""

import json
import os

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

import pytest
from app.config import get_settings
from app.tts.cache import TTSCache
from app.tts.providers import ElevenLabsTTSProvider, OpenAITTSProvider
from app.tts.service import TTSService, primary_cache_voice
from app.tts.voices import ELEVENLABS_VOICES, SpeechStyle

GEORGE = ELEVENLABS_VOICES["george"]
JOSEF = ELEVENLABS_VOICES["josef"]
FLASH = "eleven_flash_v2_5"


class FakeElevenLabs:
    """Named like the real primary so model routing applies; records styles."""

    name = "elevenlabs"
    default_voice = GEORGE
    model = "eleven_v4_turbo"

    def __init__(self):
        self.calls: list[tuple[str, str, SpeechStyle | None]] = []

    async def synthesize(self, text, voice, style=None):
        self.calls.append((text, voice, style))
        return b"new-clip"


@pytest.fixture(autouse=True)
def _env(tmp_path, monkeypatch):
    monkeypatch.setenv("TTS_CACHE_DIR", str(tmp_path / "tts"))
    monkeypatch.delenv("TTS_LANGUAGE_STYLES", raising=False)
    monkeypatch.delenv("TTS_VOICE", raising=False)


def _service(**kw) -> tuple[TTSService, FakeElevenLabs]:
    primary = FakeElevenLabs()
    svc = TTSService(provider=primary, **kw)
    svc.fallback = None
    svc.remote = None
    return svc, primary


def test_default_config_is_the_founders_decision():
    styles = get_settings().tts_language_styles
    assert styles["en"] == {"model": FLASH, "speed": 1.1}
    assert styles["sk"] == {"model": FLASH, "speed": 1.07, "language_code": "sk"}
    # Founder 2026-11-19: George reading Czech sounds foreign; Josef reads it.
    assert styles["cs"] == {
        "model": FLASH,
        "speed": 1.07,
        "language_code": "cs",
        "voice": JOSEF,
    }
    # Ukrainian keeps the v3 reading a native speaker chose (#231).
    assert "uk" not in styles


def test_slovak_and_czech_requests_name_their_language_and_speed():
    """Flash guesses the language from the text; a Slovak question full of
    names can come out in another language without `language_code`."""
    provider = ElevenLabsTTSProvider(model="eleven_v4_turbo")
    svc, _ = _service()
    for lang in ("sk", "cs"):
        payload = provider.payload_for("Aké je hlavné mesto?", svc.style_for(lang))
        assert payload == {
            "text": "Aké je hlavné mesto?",
            "model_id": FLASH,
            "voice_settings": {"speed": 1.07},
            "language_code": lang,
        }
    en = provider.payload_for("What is the capital?", svc.style_for("en"))
    assert en == {
        "text": "What is the capital?",
        "model_id": FLASH,
        "voice_settings": {"speed": 1.1},
    }


def test_ukrainian_request_is_unchanged():
    provider = ElevenLabsTTSProvider(model="eleven_v4_turbo")
    svc, _ = _service()
    assert svc.style_for("uk") is None
    assert provider.payload_for("Яка столиця?", svc.style_for("uk")) == {
        "text": "Яка столиця?",
        "model_id": "eleven_v3",
        "voice_settings": {"stability": 1.0},
    }


def test_cache_key_changes_with_model_and_speed_but_not_for_unstyled_speech():
    svc, primary = _service()
    legacy = svc._remote_key("Otázka?", GEORGE)

    sk = svc.remote_key_for("Otázka?", "sk")
    assert sk != legacy  # a faster reading must not replay the old clip
    # Unstyled speech (uk, unknown language) keeps the key every clip had, so
    # nothing already recorded is paid for again.
    assert svc.remote_key_for("Otázka?", "uk") == legacy
    assert svc.remote_key_for("Otázka?", None) == legacy

    faster = SpeechStyle(model=FLASH, speed=1.2)
    other_model = SpeechStyle(model="eleven_multilingual_v2", speed=1.07)
    base = svc._cache_voice(primary, GEORGE, svc.style_for("sk"))
    assert svc._cache_voice(primary, GEORGE, faster) != base
    assert svc._cache_voice(primary, GEORGE, other_model) != base


@pytest.mark.asyncio
async def test_old_clip_is_not_replayed_and_stays_for_a_rollback(monkeypatch):
    svc, primary = _service()
    svc.cache.set("Otázka?", GEORGE, b"old-clip")

    assert await svc.synthesize("Otázka?", language="sk") != b"old-clip"
    assert primary.calls[0][2].speed == 1.07

    # Rollback = config change: no styles -> the old clip plays, unpaid.
    monkeypatch.setenv("TTS_LANGUAGE_STYLES", "{}")
    rolled_back, again = _service(cache_dir=str(svc.cache.cache_dir))
    assert await rolled_back.synthesize("Otázka?", language="sk") == b"old-clip"
    assert again.calls == []


@pytest.mark.asyncio
async def test_over_budget_the_old_george_clip_beats_the_fallback_voice():
    """Until a clip is re-recorded, a player over budget still hears George
    (at the old speed) rather than the backup voice."""
    from app.tts.service import TTSBilling

    svc, primary = _service()
    svc.cache.set("Otázka?", GEORGE, b"old-clip")
    billing = TTSBilling(allow_primary=False)
    assert await svc.synthesize("Otázka?", language="sk", billing=billing) == (
        b"old-clip"
    )
    assert primary.calls == []


@pytest.mark.asyncio
async def test_czech_is_read_by_josef_and_the_rest_by_george():
    """A Czech question must reach ElevenLabs as Josef's voice, or Czech players
    keep hearing George's foreign accent; other languages keep George."""
    svc, primary = _service()
    await svc.synthesize("Otázka?", language="cs")
    await svc.synthesize("Otázka?", language="sk")
    await svc.synthesize("Question?", language="en")
    assert [voice for _, voice, _ in primary.calls] == [JOSEF, GEORGE, GEORGE]


@pytest.mark.asyncio
async def test_czech_does_not_replay_georges_clip_but_keeps_it_for_a_rollback():
    """George's styled Czech clip already sits in the cache for every voiced
    question; if Josef's key matched it, nothing would change for players."""
    svc, primary = _service()
    george_cs = svc._cache_voice(primary, GEORGE, svc.style_for("cs"))
    svc.cache.set("Otázka?", george_cs, b"george-clip")
    assert svc.remote_key_for("Otázka?", "cs") != svc._remote_key("Otázka?", george_cs)
    assert await svc.synthesize("Otázka?", language="cs") == b"new-clip"
    assert svc.cache.get("Otázka?", george_cs) is not None


@pytest.mark.asyncio
async def test_over_budget_czech_still_gets_the_old_george_clip():
    """Until Josef re-records a Czech clip, a player over budget hears the old
    George clip rather than the backup voice."""
    from app.tts.service import TTSBilling

    svc, primary = _service()
    svc.cache.set("Otázka?", GEORGE, b"old-clip")
    billing = TTSBilling(allow_primary=False)
    assert await svc.synthesize("Otázka?", language="cs", billing=billing) == (
        b"old-clip"
    )
    assert primary.calls == []


@pytest.mark.asyncio
async def test_config_drives_the_speed(monkeypatch):
    monkeypatch.setenv(
        "TTS_LANGUAGE_STYLES", json.dumps({"en": {"model": FLASH, "speed": 1.15}})
    )
    svc, primary = _service()
    await svc.synthesize("Question?", language="en")
    await svc.synthesize("Otázka?", language="sk")
    assert primary.calls[0][2] == SpeechStyle(model=FLASH, speed=1.15)
    assert primary.calls[1][2] is None  # sk not configured: as before


def test_static_feedback_is_recorded_again_in_the_english_style():
    """The 20 fixed phrases are English: a new English speed must re-record
    them at startup instead of serving the old reading from a warm cache."""
    svc, _ = _service()
    path = svc.cache._static_path("correct", 0).name
    assert path == "feedback_elevenlabs-eleven_flash_v2_5-1.1_correct_0.opus"


def test_read_only_tools_compute_the_apps_key():
    """social-studio's fetch_question.py finds the app's clip without a
    TTSService; it must land on the very key the app writes."""
    svc = TTSService(provider=ElevenLabsTTSProvider())
    for lang in ("en", "sk", "cs", "uk", None):
        assert (
            f"questions/{TTSCache._hash(None, 'Q?', primary_cache_voice(GEORGE, lang))}.opus"
            == svc.remote_key_for("Q?", lang)
        )


@pytest.mark.asyncio
async def test_fallback_voice_reads_at_the_language_speed():
    """A backup clip should not sound slower than the George clips around it."""
    provider = OpenAITTSProvider()
    sent = {}

    class Speech:
        async def create(self, **kwargs):
            sent.update(kwargs)
            return type("R", (), {"content": b"mp3"})()

    provider.client = type("C", (), {"audio": type("A", (), {"speech": Speech()})()})()
    svc, _ = _service()
    await provider.synthesize("Otázka?", "nova", svc.style_for("sk"))
    assert sent["speed"] == 1.07
    await provider.synthesize("Питання?", "nova", svc.style_for("uk"))
    assert sent["speed"] == 1.0
