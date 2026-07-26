"""Text-to-Speech (TTS) module for quiz audio responses.

Provides voice synthesis for questions and feedback with intelligent caching
to minimize costs. The synthesis backend is pluggable (ElevenLabs primary,
OpenAI backup) — see `providers.py`.
"""

from .service import TTSService
from .cache import TTSCache
from .providers import TTSProvider, build_provider
from .voices import VOICE_PROFILES, STATIC_FEEDBACK, ELEVENLABS_VOICES

__all__ = [
    "TTSService",
    "TTSCache",
    "TTSProvider",
    "build_provider",
    "VOICE_PROFILES",
    "STATIC_FEEDBACK",
    "ELEVENLABS_VOICES",
]
