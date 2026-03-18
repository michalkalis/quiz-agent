"""Text-to-Speech service using OpenAI TTS API.

Provides voice synthesis for quiz questions and feedback with intelligent caching.
"""

import asyncio
import io
import logging
import os
import random
from typing import Optional
from openai import AsyncOpenAI

logger = logging.getLogger(__name__)

from .cache import TTSCache
from .voices import (
    DEFAULT_VOICE,
    VOICE_PROFILES,
    STATIC_FEEDBACK,
    TTS_FORMAT,
    TTS_SPEED
)

# Volume boost setting (in decibels)
# +6dB ≈ double perceived loudness, compensates for quiet OpenAI TTS output
VOLUME_BOOST_DB = 6.0


def boost_volume(audio_data: bytes, gain_db: float = VOLUME_BOOST_DB) -> bytes:
    """Boost audio volume using pydub.

    Args:
        audio_data: Raw audio bytes (MP3 format)
        gain_db: Gain in decibels (+6dB ≈ double perceived loudness)

    Returns:
        Volume-boosted audio bytes in MP3 format

    Note:
        Requires ffmpeg installed on the system for pydub to work.
        Uses MP3 format for universal iOS AVPlayer compatibility.
    """
    try:
        from pydub import AudioSegment

        # Load MP3 audio from bytes
        audio = AudioSegment.from_file(io.BytesIO(audio_data), format="mp3")

        # Apply gain boost
        louder_audio = audio + gain_db

        # Export back to MP3 (64k bitrate is good quality for speech)
        buffer = io.BytesIO()
        louder_audio.export(buffer, format="mp3", bitrate="64k")
        return buffer.getvalue()

    except Exception as e:
        # If volume boost fails, return original audio (graceful fallback)
        logger.warning(f"Volume boost failed (returning original): {e}")
        return audio_data


class TTSService:
    """Text-to-Speech service with caching and concurrency control.

    Features:
    - OpenAI TTS API integration
    - 3-tier caching (static, LRU, dynamic)
    - Concurrency limiting (max 20 concurrent requests)
    - Multilingual support (OpenAI TTS speaks 50+ languages)
    - MP3 format (universally supported by iOS AVPlayer)

    Usage:
        >>> tts = TTSService()
        >>> await tts.pregenerate_static_feedback()
        >>> audio = await tts.synthesize("What is the capital of France?")
        >>> feedback = await tts.get_feedback_audio("correct")
    """

    def __init__(
        self,
        model: str = "tts-1",
        cache_dir: str = "./data/tts_cache",
        max_concurrent: int = 20,
        max_cache_mb: int = 100
    ):
        """Initialize TTS service.

        Args:
            model: OpenAI TTS model ("tts-1" or "tts-1-hd")
            cache_dir: Directory for audio cache
            max_concurrent: Max concurrent TTS API requests
            max_cache_mb: Max cache size in megabytes
        """
        self.client = AsyncOpenAI(api_key=os.getenv("OPENAI_API_KEY"))
        self.model = model
        self.cache = TTSCache(cache_dir=cache_dir, max_size_mb=max_cache_mb)
        self._semaphore = asyncio.Semaphore(max_concurrent)

    async def synthesize(
        self,
        text: str,
        voice: Optional[str] = None,
        use_cache: bool = True
    ) -> bytes:
        """Synthesize text to speech with caching.

        Supports any language - OpenAI TTS automatically detects language
        from input text and speaks it correctly.

        Args:
            text: Text to synthesize (any language)
            voice: Voice name (default: "nova")
            use_cache: Whether to use cache (default: True)

        Returns:
            Audio bytes in MP3 format

        Example:
            >>> audio = await tts.synthesize("Bonjour!")  # French
            >>> audio = await tts.synthesize("こんにちは")  # Japanese
            >>> audio = await tts.synthesize("Hello!")    # English
        """
        if not text.strip():
            raise ValueError("Text cannot be empty")

        voice = voice or DEFAULT_VOICE

        # Check cache first
        if use_cache:
            cached = self.cache.get(text, voice)
            if cached:
                return cached

        # Generate via OpenAI TTS
        async with self._semaphore:
            try:
                response = await self.client.audio.speech.create(
                    model=self.model,
                    voice=voice,
                    input=text,
                    response_format=TTS_FORMAT,
                    speed=TTS_SPEED
                )

                # Read audio bytes
                audio_data = response.content

                # Apply volume boost (+6dB ≈ double perceived loudness)
                audio_data = boost_volume(audio_data)

                # Cache result (cache the boosted version)
                if use_cache:
                    self.cache.set(text, voice, audio_data)

                return audio_data

            except Exception as e:
                raise RuntimeError(f"TTS synthesis failed: {str(e)}")

    async def get_feedback_audio(
        self,
        result: str,
        variant: Optional[int] = None
    ) -> Optional[bytes]:
        """Get pre-cached feedback audio.

        Args:
            result: Evaluation result (correct, incorrect, partially_correct, skipped)
            variant: Specific phrase variant, or random if None

        Returns:
            Audio bytes if available, None otherwise

        Example:
            >>> audio = await tts.get_feedback_audio("correct")
            >>> audio = await tts.get_feedback_audio("incorrect", variant=0)
        """
        # Get available phrases for this result
        phrases = STATIC_FEEDBACK.get(result, [])
        if not phrases:
            return None

        # Select variant
        if variant is None:
            variant = random.randint(0, len(phrases) - 1)
        elif variant >= len(phrases):
            variant = 0

        # Get from static cache
        return self.cache.get_static_feedback(result, variant)

    async def pregenerate_static_feedback(self):
        """Pre-generate all static feedback phrases.

        Called on server startup to ensure instant feedback playback.
        Total cost: ~$0.05 one-time (12 phrases × ~8 chars × $15/1M chars)

        This creates audio files for all feedback variants:
        - feedback_correct_0.opus ("Correct!")
        - feedback_correct_1.opus ("Well done!")
        - feedback_incorrect_0.opus ("Not quite.")
        - etc.
        """
        logger.info("Pre-generating static feedback audio...")

        total_generated = 0
        total_skipped = 0

        for result, phrases in STATIC_FEEDBACK.items():
            for i, phrase in enumerate(phrases):
                # Check if already exists
                existing = self.cache.get_static_feedback(result, i)
                if existing:
                    total_skipped += 1
                    continue

                # Generate new audio
                try:
                    audio_data = await self.synthesize(
                        text=phrase,
                        voice=DEFAULT_VOICE,
                        use_cache=False  # Don't cache in LRU, goes to static
                    )

                    # Store in static cache
                    self.cache.set_static_feedback(result, i, audio_data)
                    total_generated += 1

                    logger.debug("Generated: %s variant %d - \"%s\"", result, i, phrase)

                except Exception as e:
                    logger.error("Failed to generate %s variant %d: %s", result, i, e)

        logger.info("Static feedback ready: %d generated, %d already cached", total_generated, total_skipped)

    def get_cache_stats(self) -> dict:
        """Get cache statistics.

        Returns:
            Dictionary with cache stats including:
            - questions_cached: Number of cached questions
            - questions_size_mb: Size of question cache
            - static_feedback_files: Number of static feedback files
            - static_size_mb: Size of static cache
            - total_size_mb: Total cache size
        """
        return self.cache.get_cache_stats()

    def clear_question_cache(self):
        """Clear the question cache (LRU cache).

        Static feedback cache is NOT cleared.
        """
        for entry in self.cache.lru.values():
            try:
                if entry.path.exists():
                    entry.path.unlink()
            except Exception:
                pass

        self.cache.lru = {}
        self.cache._save_metadata()

    async def synthesize_question(
        self,
        question_text: str,
        voice: Optional[str] = None
    ) -> bytes:
        """Synthesize quiz question with caching.

        Optimized for questions - uses LRU cache with high hit rate.

        Args:
            question_text: Question text (any language)
            voice: Voice name (default: "nova")

        Returns:
            Audio bytes in MP3 format
        """
        return await self.synthesize(
            text=question_text,
            voice=voice,
            use_cache=True
        )
