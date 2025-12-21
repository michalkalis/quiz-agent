"""Voice profiles and static feedback phrases for TTS.

Defines voice configurations and pre-generated feedback audio content.
"""

from typing import Dict, List

# Voice profiles for different use cases
VOICE_PROFILES: Dict[str, str] = {
    "default": "nova",       # Female, warm, clear (best for quiz questions)
    "alternate": "shimmer",  # Female, upbeat (for positive feedback)
    "formal": "onyx",        # Male, authoritative (optional alternative)
}

# Default voice for all TTS operations
DEFAULT_VOICE = VOICE_PROFILES["default"]

# Static feedback phrases organized by evaluation result
# These will be pre-generated on server startup for instant playback
STATIC_FEEDBACK: Dict[str, List[str]] = {
    "correct": [
        "Correct!",
        "Well done!",
        "Exactly right!",
        "Perfect!",
    ],
    "incorrect": [
        "Not quite.",
        "Try again.",
        "Close, but not quite.",
        "Incorrect.",
    ],
    "partially_correct": [
        "Partially correct.",
        "You're on the right track.",
        "Almost there!",
    ],
    "skipped": [
        "Skipped.",
        "Moving on.",
    ],
}

# Audio format configuration
TTS_FORMAT = "opus"  # Opus format (24kbps, iOS native support, 5x smaller than MP3)
TTS_SPEED = 1.0      # Normal speech speed
