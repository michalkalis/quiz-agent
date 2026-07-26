"""Voice profiles and static feedback phrases for TTS.

Defines voice configurations and pre-generated feedback audio content.
"""

from typing import Dict, List

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
}

ELEVENLABS_DEFAULT_VOICE = ELEVENLABS_VOICES["george"]

# `eleven_multilingual_v2` is the quality tier and the one the founder approved
# for Slovak. `eleven_flash_v2_5` is half the credits and much lower latency but
# weaker on non-English pronunciation — switch via `ELEVENLABS_TTS_MODEL`.
ELEVENLABS_DEFAULT_MODEL = "eleven_multilingual_v2"
ELEVENLABS_OUTPUT_FORMAT = "mp3_44100_128"

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
