"""Text-to-Speech (TTS) module for quiz audio responses.

Provides voice synthesis for questions and feedback using OpenAI TTS API
with intelligent caching to minimize costs.
"""

from .service import TTSService
from .cache import TTSCache
from .voices import VOICE_PROFILES, STATIC_FEEDBACK, DEFAULT_VOICE

__all__ = [
    "TTSService",
    "TTSCache",
    "VOICE_PROFILES",
    "STATIC_FEEDBACK",
    "DEFAULT_VOICE",
]
