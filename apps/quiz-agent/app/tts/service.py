"""Text-to-Speech service with a pluggable synthesis backend.

Provides voice synthesis for quiz questions and feedback with intelligent
caching. Which vendor actually speaks is decided in `providers.py` and chosen
by config — this layer owns caching, loudness and the static-feedback tier.
"""

import asyncio
import io
import logging
import random
from typing import Optional

from ..config import get_settings
from .cache import TTSCache
from .providers import TTSProvider, build_provider
from .voices import STATIC_FEEDBACK

logger = logging.getLogger(__name__)

# Target peak level after volume boost (in dBFS)
# 0 dBFS = maximum digital level. We target -0.5 to leave tiny headroom.
TARGET_PEAK_DBFS = -0.5

# Additional boost after normalization (in dB)
# Applied on top of normalization — causes soft clipping on peaks
# but increases perceived loudness significantly for speech.
# +3dB on top of normalization ≈ 2x louder than old +6dB flat boost
POST_NORMALIZE_BOOST_DB = 3.0


def boost_volume(
    audio_data: bytes,
    target_peak: float = TARGET_PEAK_DBFS,
    extra_boost: float = POST_NORMALIZE_BOOST_DB,
) -> bytes:
    """Maximize audio volume: normalize to peak, then apply extra boost.

    Strategy: First normalize so the loudest peak hits target_peak dBFS,
    then apply a small extra boost for perceived loudness (speech tolerates
    mild peak clipping well). Net effect is significantly louder than the
    previous flat +6dB boost.

    Args:
        audio_data: Raw audio bytes (MP3 format)
        target_peak: Normalize peak to this level in dBFS (-0.5 default)
        extra_boost: Additional gain in dB after normalization (+3 default)

    Returns:
        Volume-boosted audio bytes in MP3 format
    """
    try:
        from pydub import AudioSegment

        audio = AudioSegment.from_file(io.BytesIO(audio_data), format="mp3")

        # Step 1: Normalize — bring peak to target level
        peak_db = audio.max_dBFS
        normalization_gain = target_peak - peak_db
        normalized = audio + normalization_gain

        # Step 2: Extra boost for perceived loudness (mild clipping is OK for speech)
        louder_audio = normalized + extra_boost

        # Export back to MP3 (64k bitrate is good quality for speech)
        buffer = io.BytesIO()
        louder_audio.export(buffer, format="mp3", bitrate="64k")
        return buffer.getvalue()

    except Exception as e:
        logger.warning(f"Volume boost failed (returning original): {e}")
        return audio_data


def _model_for(name: str, settings) -> Optional[str]:
    return {
        "elevenlabs": settings.elevenlabs_tts_model,
        "openai": settings.openai_tts_model,
    }.get(name.strip().lower())


def _resolve_provider(
    name: Optional[str], settings, voice: Optional[str] = None
) -> Optional[TTSProvider]:
    """Build a provider from a config name; None/"none" means "not configured".

    `voice` is only ever passed for the primary: a `TTS_VOICE` override is an
    ElevenLabs voice id or an OpenAI voice name, and handing one to the other
    vendor would break the very failover it is meant to survive.
    """
    if name is None or not name.strip() or name.strip().lower() == "none":
        return None
    return build_provider(name, model=_model_for(name, settings), voice=voice)


class TTSService:
    """Text-to-Speech service with caching and concurrency control.

    Features:
    - Pluggable synthesis backend (ElevenLabs primary, OpenAI backup)
    - Automatic failover to the backup provider on synthesis failure
    - 3-tier caching (static, LRU, dynamic)
    - Concurrency limiting (max 20 concurrent requests)
    - Multilingual support (both providers speak 30+ languages)
    - MP3 format (universally supported by iOS AVPlayer)

    Usage:
        >>> tts = TTSService()
        >>> await tts.pregenerate_static_feedback()
        >>> audio = await tts.synthesize("What is the capital of France?")
        >>> feedback = await tts.get_feedback_audio("correct")
    """

    def __init__(
        self,
        provider: Optional[TTSProvider] = None,
        fallback_provider: Optional[TTSProvider] = None,
        cache_dir: Optional[str] = None,
        max_concurrent: int = 20,
        max_cache_mb: int = 100,
    ):
        """Initialize TTS service.

        Args:
            provider: Synthesis backend; defaults to `TTS_PROVIDER` (elevenlabs)
            fallback_provider: Backend used when the primary fails; defaults to
                `TTS_FALLBACK_PROVIDER` (openai). Set to "none" to disable.
            cache_dir: Directory for audio cache; defaults to `TTS_CACHE_DIR`
            max_concurrent: Max concurrent TTS API requests
            max_cache_mb: Max cache size in megabytes
        """
        settings = get_settings()
        self.provider = provider or _resolve_provider(
            settings.tts_provider, settings, voice=settings.tts_voice
        )
        if self.provider is None:
            raise ValueError("TTS_PROVIDER must name a provider, not 'none'")

        self.fallback = fallback_provider or _resolve_provider(
            settings.tts_fallback_provider, settings
        )
        if self.fallback is not None and self.fallback.name == self.provider.name:
            # Swapping is meant to be a one-line change: flipping `TTS_PROVIDER`
            # to the configured fallback makes the *other* engine the backup,
            # rather than silently leaving the deploy with no backup at all.
            # (Two providers exist; revisit if a third is ever added.)
            self.fallback = _resolve_provider(
                next(
                    (n for n in ("elevenlabs", "openai") if n != self.provider.name),
                    None,
                ),
                settings,
            )

        # Static feedback is namespaced by provider so flipping `TTS_PROVIDER`
        # cannot serve yesterday's voice out of a warm cache.
        self.cache = TTSCache(
            cache_dir=cache_dir or settings.tts_cache_dir,
            max_size_mb=max_cache_mb,
            provider=self.provider.name,
        )
        self._semaphore = asyncio.Semaphore(max_concurrent)

        logger.info(
            "TTS provider: %s (fallback: %s)",
            self.provider.name,
            self.fallback.name if self.fallback else "none",
        )

    async def synthesize(
        self, text: str, voice: Optional[str] = None, use_cache: bool = True
    ) -> bytes:
        """Synthesize text to speech with caching, failing over to the backup.

        Supports any language - both providers detect the language from the
        input text and speak it correctly.

        Args:
            text: Text to synthesize (any language)
            voice: Voice id/name (default: the active provider's default)
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

        primary_voice = voice or self.provider.default_voice

        try:
            return await self._synthesize_with(
                self.provider, text, primary_voice, use_cache
            )
        except Exception as primary_error:
            if self.fallback is None:
                raise RuntimeError(f"TTS synthesis failed: {primary_error}")

            # The primary is the metered one (ElevenLabs credits are shared with
            # realtime STT), so a quota wall here must degrade the voice, not
            # silence the question.
            logger.warning(
                "TTS provider %s failed, falling back to %s: %s",
                self.provider.name,
                self.fallback.name,
                primary_error,
            )
            try:
                return await self._synthesize_with(
                    self.fallback, text, self.fallback.default_voice, use_cache
                )
            except Exception as fallback_error:
                raise RuntimeError(
                    f"TTS synthesis failed on {self.provider.name} "
                    f"({primary_error}) and on fallback {self.fallback.name} "
                    f"({fallback_error})"
                )

    async def _synthesize_with(
        self, provider: TTSProvider, text: str, voice: str, use_cache: bool
    ) -> bytes:
        """Cache lookup → synthesis → volume boost → cache store, for one backend.

        The cache key is (text, voice) and voices never collide across vendors
        (ElevenLabs uses opaque ids, OpenAI uses names like "nova"), so primary
        and fallback audio coexist in one cache without shadowing each other.
        """
        if use_cache:
            cached = self.cache.get(text, voice)
            if cached:
                return cached

        async with self._semaphore:
            audio_data = await provider.synthesize(text, voice)

        # Apply volume boost (normalize + extra boost for max loudness)
        audio_data = boost_volume(audio_data)

        # Cache result (cache the boosted version)
        if use_cache:
            self.cache.set(text, voice, audio_data)

        return audio_data

    async def get_feedback_audio(
        self, result: str, variant: Optional[int] = None
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

        Called on server startup to ensure instant feedback playback. Skipped
        for phrases already on disk, so the real cost is paid once per provider
        per cache volume: ~250 ElevenLabs credits (1 credit/char) or ~$0.005 on
        OpenAI. Note that an ephemeral cache dir turns "once" into "every
        deploy" — see `TTS_CACHE_DIR`.

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
                        use_cache=False,  # Don't cache in LRU, goes to static
                    )

                    # Store in static cache
                    self.cache.set_static_feedback(result, i, audio_data)
                    total_generated += 1

                    logger.debug('Generated: %s variant %d - "%s"', result, i, phrase)

                except Exception as e:
                    logger.error("Failed to generate %s variant %d: %s", result, i, e)

        logger.info(
            "Static feedback ready: %d generated, %d already cached",
            total_generated,
            total_skipped,
        )

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
        self, question_text: str, voice: Optional[str] = None
    ) -> bytes:
        """Synthesize quiz question with caching.

        Optimized for questions - uses LRU cache with high hit rate.

        Args:
            question_text: Question text (any language)
            voice: Voice name (default: "nova")

        Returns:
            Audio bytes in MP3 format
        """
        return await self.synthesize(text=question_text, voice=voice, use_cache=True)
