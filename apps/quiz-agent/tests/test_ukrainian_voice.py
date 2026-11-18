"""#231 — how Ukrainian is read aloud (native speaker blind test 2026-11-18)."""

from types import SimpleNamespace

import pytest

from app.tts.number_normalization import normalize_numbers_for_tts
from app.tts.providers import ElevenLabsTTSProvider
from app.tts.service import _resolve_provider


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
