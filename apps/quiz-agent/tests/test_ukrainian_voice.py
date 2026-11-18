"""#231 — how Ukrainian is read aloud (native speaker blind test 2026-11-18)."""

import asyncio
import json
import logging
from types import SimpleNamespace

import httpx
import pytest

from app.tts import service as service_module
from app.tts.number_normalization import normalize_numbers_for_tts
from app.tts.providers import ElevenLabsTTSProvider
from app.tts.service import TTSService, _resolve_provider, primary_cache_voice
from app.tts.voices import SpeechStyle


def test_ukrainian_text_reads_on_v3_everything_else_stays_on_the_default():
    """v4 Turbo misplaced stress in 4 of 5 Ukrainian questions; v3 read all of
    them right. sk/cs/en must keep the cheaper, faster default."""
    provider = ElevenLabsTTSProvider(model="eleven_v4_turbo")
    assert provider.model_for("Яка столиця Австралії?") == "eleven_v3"
    assert provider.model_for("Aké je hlavné mesto Austrálie?") == "eleven_v4_turbo"
    assert provider.model_for("Jaké je hlavní město Austrálie?") == "eleven_v4_turbo"
    assert provider.model_for("What is the capital of Australia?") == "eleven_v4_turbo"


def test_ukrainian_requests_pin_the_stable_voice_setting_others_are_unchanged():
    """At v3's default two of eleven Ukrainian questions sounded like another
    voice (native speaker, round 4). sk/cs/en requests must stay byte-identical."""
    provider = ElevenLabsTTSProvider(model="eleven_v4_turbo")
    assert provider.payload_for("Яка столиця Австралії?") == {
        "text": "Яка столиця Австралії?",
        "model_id": "eleven_v3",
        "voice_settings": {"stability": 1.0},
    }
    assert provider.payload_for("Aké je hlavné mesto Austrálie?") == {
        "text": "Aké je hlavné mesto Austrálie?",
        "model_id": "eleven_v4_turbo",
    }


def test_service_wires_the_cyrillic_model_from_settings():
    settings = SimpleNamespace(
        elevenlabs_tts_model="eleven_v4_turbo",
        openai_tts_model="tts-1",
        elevenlabs_tts_model_cyrillic="eleven_multilingual_v2",
    )
    provider = _resolve_provider("elevenlabs", settings)
    assert provider.model_for("Київ") == "eleven_multilingual_v2"
    assert provider.model_for("Kyjev") == "eleven_v4_turbo"
    # The OpenAI fallback has no per-script model and must still build.
    assert _resolve_provider("openai", settings) is not None


@pytest.mark.parametrize(
    ("text", "spoken"),
    [
        # Native speaker: "Fe" came out as "еф і"; "ферум" makes it obvious.
        (
            "Який хімічний елемент позначають символом Fe?",
            "Який хімічний елемент позначають символом ферум?",
        ),
        ("Символ Au означає золото", "Символ аурум означає золото"),
        # Only after "символ/позначка": a grade "C" or an unknown token stays.
        ("Оцінка C за тест", "Оцінка C за тест"),
        ("Який елемент має символ Xy?", "Який елемент має символ Xy?"),
    ],
)
def test_chemical_symbols_are_read_the_ukrainian_school_way(text, spoken):
    assert normalize_numbers_for_tts(text, "uk") == spoken


def test_slovak_symbols_are_untouched():
    assert normalize_numbers_for_tts("Ktorý prvok má značku Fe?", "sk") == (
        "Ktorý prvok má značku Fe?"
    )


# ── What synthesis sends, how it is cached, how long it may take ────────────

UK_QUESTION = "Яка столиця Австралії?"
SK_QUESTION = "Aké je hlavné mesto Austrálie?"


def _capture_elevenlabs(monkeypatch) -> list[dict]:
    """Route ElevenLabs HTTP to a stub that records each request body."""
    sent: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        sent.append(json.loads(request.content))
        return httpx.Response(200, content=b"mp3-bytes")

    real_init = httpx.AsyncClient.__init__

    def patched_init(self, *args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(handler)
        real_init(self, *args, **kwargs)

    monkeypatch.setattr(httpx.AsyncClient, "__init__", patched_init)
    return sent


@pytest.fixture
def tts_env(tmp_path, monkeypatch):
    monkeypatch.setenv("TTS_CACHE_DIR", str(tmp_path / "tts_cache"))
    monkeypatch.setenv("ELEVENLABS_API_KEY", "test-key")
    return monkeypatch


@pytest.mark.asyncio
async def test_synthesize_sends_v3_and_its_stability_only_together(tts_env):
    """Stability 1.0 was tuned on eleven_v3; a rollback model must get its
    own defaults, and sk/cs/en bodies stay byte-identical."""
    sent = _capture_elevenlabs(tts_env)
    v3 = ElevenLabsTTSProvider(model="eleven_v4_turbo")
    rollback = ElevenLabsTTSProvider(
        model="eleven_v4_turbo", cyrillic_model="eleven_multilingual_v2"
    )

    await v3.synthesize(UK_QUESTION, "george-id")
    await rollback.synthesize(UK_QUESTION, "george-id")
    await v3.synthesize(SK_QUESTION, "george-id")

    assert sent == [
        {
            "text": UK_QUESTION,
            "model_id": "eleven_v3",
            "voice_settings": {"stability": 1.0},
        },
        {"text": UK_QUESTION, "model_id": "eleven_multilingual_v2"},
        {"text": SK_QUESTION, "model_id": "eleven_v4_turbo"},
    ]


class _Backup:
    name, default_voice = "openai", "nova"

    async def synthesize(self, text, voice, style=None):
        return b"backup-audio"


@pytest.mark.asyncio
async def test_new_cyrillic_settings_make_new_audio_latin_keys_stay(tts_env):
    """A clip made with older Cyrillic model/settings must not replay forever;
    the Latin cache (thousands of paid clips) must keep its exact keys."""
    sent = _capture_elevenlabs(tts_env)
    first = TTSService(provider=ElevenLabsTTSProvider(), fallback_provider=_Backup())
    await first.synthesize(UK_QUESTION)
    await first.synthesize(SK_QUESTION)
    await first.synthesize(UK_QUESTION)  # cached
    assert len(sent) == 2

    voice = first.provider.default_voice
    assert first.cache.get(SK_QUESTION, voice) is not None  # key is (text, voice)
    assert first.cache.get(UK_QUESTION, voice) is None

    rolled_back = TTSService(
        provider=ElevenLabsTTSProvider(cyrillic_model="eleven_multilingual_v2"),
        fallback_provider=_Backup(),
    )
    await rolled_back.synthesize(UK_QUESTION)
    await rolled_back.synthesize(SK_QUESTION)
    assert [body["model_id"] for body in sent[2:]] == ["eleven_multilingual_v2"]


class _SlowElevenLabs:
    """Answers after ``delay`` seconds; has the model switch of the real one."""

    name, default_voice = "elevenlabs", "george-id"

    def __init__(self, delay: float):
        self.delay = delay

    def model_for(self, text, style=None):
        return "eleven_v3" if any("а" <= ch <= "я" for ch in text) else "turbo"

    async def synthesize(self, text, voice, style=None):
        await asyncio.sleep(self.delay)
        return b"george-audio"


def test_cyrillic_cut_off_defaults_inside_the_apps_wait_and_reads_env(tts_env):
    """The app stops waiting at 10 s; the founder's range for the primary's
    share is 6–8 s. The slower Cyrillic model gets the top of it."""
    service = TTSService(provider=_SlowElevenLabs(0), fallback_provider=_Backup())
    assert service._primary_timeout(UK_QUESTION) == 8.0
    assert service._primary_timeout(SK_QUESTION) == 6.0
    tts_env.setenv("TTS_PRIMARY_TIMEOUT_CYRILLIC_S", "7.5")
    service = TTSService(provider=_SlowElevenLabs(0), fallback_provider=_Backup())
    assert service._primary_timeout(UK_QUESTION) == 7.5


@pytest.mark.asyncio
async def test_slower_cyrillic_model_keeps_the_tested_voice(tts_env, caplog):
    """A Ukrainian question slower than the Latin limit still gets the voice a
    native speaker approved; Latin text past it falls back, logged with the
    model so a v3 slowdown is visible in triage."""
    tts_env.setattr(service_module, "PRIMARY_TTS_TIMEOUT_S", 0.01)
    service = TTSService(provider=_SlowElevenLabs(0.05), fallback_provider=_Backup())
    service.primary_timeout_cyrillic_s = 1.0

    assert await service.synthesize(UK_QUESTION) == b"george-audio"
    with caplog.at_level(logging.WARNING, logger="app.tts.service"):
        assert await service.synthesize(SK_QUESTION) == b"backup-audio"
    assert "(model turbo)" in caplog.text

    service.primary_timeout_cyrillic_s = 0.01
    with caplog.at_level(logging.WARNING, logger="app.tts.service"):
        assert await service.synthesize("Хто написав «Кобзар»?") == b"backup-audio"
    assert "(model eleven_v3)" in caplog.text


def test_a_ukrainian_style_reaches_v3_and_its_cache_key(tts_env):
    """#895 styles: uk has none by default; one set later (e.g. a speed) is
    sent with v3's stability and makes new clips, and its model can never
    replace v3. Read-only tools find the same key the app writes."""
    provider = ElevenLabsTTSProvider()
    faster = SpeechStyle(model="eleven_flash_v2_5", speed=1.05, language_code="uk")
    assert provider.payload_for(UK_QUESTION, faster) == {
        "text": UK_QUESTION,
        "model_id": "eleven_v3",
        "voice_settings": {"stability": 1.0, "speed": 1.05},
        "language_code": "uk",
    }
    plain = TTSService._cache_voice(provider, "george-id", None, UK_QUESTION)
    styled = TTSService._cache_voice(provider, "george-id", faster, UK_QUESTION)
    assert len({plain, styled, "george-id"}) == 3

    service = TTSService(provider=provider, fallback_provider=_Backup())
    voice = primary_cache_voice("george-id", "uk", text=UK_QUESTION)
    assert service.remote_key_for(
        UK_QUESTION, "uk", "george-id"
    ) == service._remote_key(UK_QUESTION, voice)
