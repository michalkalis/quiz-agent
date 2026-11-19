"""Voice profiles and static feedback phrases for TTS.

Defines voice configurations and pre-generated feedback audio content.
"""

from dataclasses import dataclass
from typing import Any, Dict, List, Mapping, Optional

# Voice profiles for different use cases (OpenAI TTS — the backup provider)
VOICE_PROFILES: Dict[str, str] = {
    "default": "nova",  # Female, warm, clear (best for quiz questions)
    "alternate": "shimmer",  # Female, upbeat (for positive feedback)
    "formal": "onyx",  # Male, authoritative (optional alternative)
}

OPENAI_DEFAULT_VOICE = VOICE_PROFILES["default"]
OPENAI_DEFAULT_MODEL = "tts-1"

# ElevenLabs voice ids (the primary provider). George won the 2026-07-26
# listening test on both English and Slovak reads; the rest are the other
# shortlisted premade voices, kept so switching host voice is a config change.
ELEVENLABS_VOICES: Dict[str, str] = {
    "george": "JBFqnCBsd6RMkjVDRZzb",  # British male, warm storyteller — quiz host
    "sarah": "EXAVITQu4vr4xnSDxMaL",  # American female, reassuring
    "alice": "Xb7hH8MSUJpSbSDYk0k2",  # British female, clear educator
    "brian": "nPczCjzI2devNBz1zQrb",  # Deep male, unhurried
    # Native Czech male from the ElevenLabs voice library (rate 1.0, 730-day
    # notice period). Founder 2026-11-19: George reading Czech sounds foreign,
    # Josef reads Czech in the app and the social videos.
    "josef": "RxVyXZsJK1kay0fTKgd2",
}

ELEVENLABS_DEFAULT_VOICE = ELEVENLABS_VOICES["george"]

# `eleven_v4_turbo` is half the price of `eleven_multilingual_v2` ($40 vs $80
# per 1M characters) and the founder heard no real difference in the 2026-10-26
# blind test (sk/cs/en, docs/research/tts-provider-alternatives-2026-10-25.md).
# The unstyled cache key is (text, voice) (Cyrillic adds the model and settings,
# #231), so audio made by v2 keeps playing;
# roll back via `ELEVENLABS_TTS_MODEL=eleven_multilingual_v2`. Since 2026-11-18
# en/sk/cs read on `eleven_flash_v2_5` with a speed (`TTS_LANGUAGE_STYLES`,
# config.py): v4 Turbo ignores `speed`, and Flash given `language_code`
# passed the founder's listening test that it failed without one.
ELEVENLABS_DEFAULT_MODEL = "eleven_v4_turbo"
# #231: Ukrainian (the only Cyrillic quiz language) reads on `eleven_v3`. A native
# speaker heard v4 Turbo misplace stress in 4 of 5 questions; v3 with the same
# voice read all of them right (blind test 2026-11-18). v3 takes ~3.5 s per
# question instead of ~1.6 s, so it stays scoped to Cyrillic text.
ELEVENLABS_CYRILLIC_MODEL = "eleven_v3"
# v3 at its default ("Natural") read 2 of 11 Ukrainian questions in what a
# native speaker heard as a different voice; "Robust" (1.0) kept all 11 the same
# voice (round 4, 2026-11-18). Tuned on v3 only, so sent only to v3: a rollback
# via `ELEVENLABS_TTS_MODEL_CYRILLIC` gets that model's own defaults.
ELEVENLABS_CYRILLIC_STABILITY = 1.0
ELEVENLABS_CYRILLIC_STABILITY_MODEL = "eleven_v3"
ELEVENLABS_OUTPUT_FORMAT = "mp3_44100_128"


@dataclass(frozen=True)
class SpeechStyle:
    """How one quiz language is read (`TTS_LANGUAGE_STYLES`, config.py).

    ``model`` is the ElevenLabs model for that language (the OpenAI backup keeps
    its own model), ``speed`` applies to both providers, ``language_code`` is
    sent to ElevenLabs so Flash does not guess the language from the text,
    ``voice`` is the ElevenLabs voice id that reads the language (None = the
    provider's default voice; the OpenAI backup keeps its own voice).
    """

    model: Optional[str] = None
    speed: Optional[float] = None
    language_code: Optional[str] = None
    voice: Optional[str] = None


def speech_style(
    language: Optional[str], styles: Mapping[str, Mapping[str, Any]]
) -> Optional[SpeechStyle]:
    """The configured style of a quiz language; None = the voice as before."""
    raw = styles.get((language or "").strip().lower())
    if not raw:
        return None
    speed = raw.get("speed")
    return SpeechStyle(
        model=raw.get("model") or None,
        speed=float(speed) if speed is not None else None,
        language_code=raw.get("language_code") or None,
        voice=raw.get("voice") or None,
    )


def cache_voice(voice: str, model: Optional[str], style: Optional[SpeechStyle]) -> str:
    """The voice part of a cache key: the voice alone for unstyled speech (the
    key every clip had before styles), else voice + model + speed, so a faster
    or other-model reading never replays the old clip and the old clip stays
    in R2 for a rollback."""
    if style is None:
        return voice
    return f"{voice}:{model}:{style.speed or 1.0:g}"


# Static feedback phrases organized by evaluation result
# These will be pre-generated on server startup for instant playback
STATIC_FEEDBACK: Dict[str, List[str]] = {
    "correct": [
        "Correct!",
        "Well done!",
        "Exactly right!",
        "Perfect!",
        "Nailed it!",
        "Spot on!",
        "You got it!",
    ],
    "incorrect": [
        "Not quite.",
        "Close, but no.",
        "Incorrect.",
        "Almost!",
        "Not this time.",
    ],
    "partially_correct": [
        "Partially correct.",
        "You're on the right track.",
        "Almost there!",
        "Close enough!",
        "Halfway there.",
    ],
    "skipped": [
        "Skipped.",
        "Moving on.",
        "Next question.",
    ],
}

# Audio format configuration
# MP3 format: Universally supported by iOS AVPlayer (unlike OggOpus)
# Note: Opus is NOT natively supported by AVPlayer in Ogg containers
TTS_FORMAT = "mp3"
TTS_SPEED = 1.0  # Normal speech speed
