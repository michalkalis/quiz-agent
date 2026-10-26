"""Text-to-Speech service with a pluggable synthesis backend.

Provides voice synthesis for quiz questions and feedback with intelligent
caching. Which vendor actually speaks is decided in `providers.py` and chosen
by config — this layer owns caching, loudness and the static-feedback tier.
"""

import asyncio
import io
import logging
import random
from dataclasses import dataclass
from typing import Optional

from ..config import get_settings
from .cache import TTSCache
from .remote_cache import R2AudioStore
from .providers import TTSProvider, build_provider
from .voices import STATIC_FEEDBACK

logger = logging.getLogger(__name__)

# #207.20 cross-machine single-flight: the synthesizing machine holds a lease
# this long; the other polls R2 for its upload, then synthesizes itself.
TTS_LEASE_TTL_S = 30.0
TTS_SHARED_WAIT_S = 10.0
TTS_SHARED_POLL_S = 0.5

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


class TTSBudgetExceeded(Exception):
    """Billed primary is over budget and there is no fallback provider."""


@dataclass
class TTSBilling:
    """Per-request budget gate (#193.13), shared between route and service.

    The route sets ``allow_primary`` from the caller's daily budget; the service
    records in ``billed_chars`` what the metered primary was actually asked to
    speak (cache hits and fallback audio stay 0), so only real spend is counted.
    """

    allow_primary: bool = True
    billed_chars: int = 0


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
        max_cache_mb: Optional[int] = None,
    ):
        """Initialize TTS service.

        Args:
            provider: Synthesis backend; defaults to `TTS_PROVIDER` (elevenlabs)
            fallback_provider: Backend used when the primary fails; defaults to
                `TTS_FALLBACK_PROVIDER` (openai). Set to "none" to disable.
            cache_dir: Directory for audio cache; defaults to `TTS_CACHE_DIR`
            max_concurrent: Max concurrent TTS API requests
            max_cache_mb: Max cache size in megabytes; defaults to `TTS_CACHE_MAX_MB`
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
            max_size_mb=max_cache_mb or settings.tts_cache_max_mb,
            provider=self.provider.name,
        )
        self._semaphore = asyncio.Semaphore(max_concurrent)
        # Single-flight: identical (text, voice) requests in flight share one
        # synthesis. The serve-time prefetch and the client's own fetch land
        # within ~100 ms of each other on every first question (prod logs
        # 2026-09-13), both missed the cache and both paid the provider.
        self._in_flight: dict[tuple[str, str], "asyncio.Task[bytes]"] = {}
        # #207.13: service-wide ElevenLabs daily budget (wired in main.py).
        # Past it, new speech uses the fallback voice; None = no budget.
        self.primary_budget = None
        # #207.20: the disk cache is a per-machine L1; R2 is the durable L2
        # every machine shares (None without its env: dev/tests). ``leases``
        # (wired in main.py) makes single-flight work across machines too.
        self.remote: Optional[R2AudioStore] = R2AudioStore.from_env()
        self.leases = None

        logger.info(
            "TTS provider: %s (fallback: %s)",
            self.provider.name,
            self.fallback.name if self.fallback else "none",
        )

    async def synthesize(
        self,
        text: str,
        voice: Optional[str] = None,
        use_cache: bool = True,
        billing: Optional[TTSBilling] = None,
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
        if await self._primary_paused():
            # Same path as a user over their own budget: cached primary audio
            # is still free to serve, anything new goes to the fallback.
            billing = billing or TTSBilling()
            billing.allow_primary = False
        # A budget-blocked caller must not share a single-flight task with
        # (or seed one for) callers who are allowed the primary voice.
        if not use_cache or (billing and not billing.allow_primary):
            return await self._synthesize_failover(
                text, primary_voice, use_cache, billing
            )

        key = (text, primary_voice)
        task = self._in_flight.get(key)
        if task is None:
            task = asyncio.create_task(
                self._synthesize_failover(text, primary_voice, use_cache, billing)
            )
            self._in_flight[key] = task
            task.add_done_callback(self._forget_in_flight(key))
        # Shielded: a caller that goes away (client disconnect) must not cancel
        # the shared synthesis under the other waiters — or the cache warm-up.
        return await asyncio.shield(task)

    async def _primary_paused(self) -> bool:
        """The service spent today's ElevenLabs budget (#207.13). Never pauses
        without a fallback: a question must not go silent over a budget."""
        return (
            self.primary_budget is not None
            and self.fallback is not None
            and self.provider.name == "elevenlabs"
            and await self.primary_budget.exhausted()
        )

    def _forget_in_flight(self, key: tuple[str, str]):
        def _done(task: "asyncio.Task[bytes]") -> None:
            if self._in_flight.get(key) is task:
                del self._in_flight[key]

        return _done

    async def _synthesize_failover(
        self,
        text: str,
        primary_voice: str,
        use_cache: bool,
        billing: Optional[TTSBilling] = None,
    ) -> bytes:
        """Primary provider, then the fallback — one synthesis, no coalescing."""
        try:
            if billing and not billing.allow_primary:
                # Over budget: already-cached primary audio is free to serve,
                # anything that would cost credits goes to the fallback.
                cached = (
                    await self._cached_audio(text, primary_voice) if use_cache else None
                )
                if cached:
                    return cached
                if self.fallback is None:
                    raise TTSBudgetExceeded()
                raise RuntimeError("daily TTS budget exhausted")
            return await self._synthesize_with(
                self.provider, text, primary_voice, use_cache, billing
            )
        except TTSBudgetExceeded:
            raise
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
        self,
        provider: TTSProvider,
        text: str,
        voice: str,
        use_cache: bool,
        billing: Optional[TTSBilling] = None,
    ) -> bytes:
        """Cache lookup → synthesis → volume boost → cache store, for one backend.

        The cache key is (text, voice) and voices never collide across vendors
        (ElevenLabs uses opaque ids, OpenAI uses names like "nova"), so primary
        and fallback audio coexist in one cache without shadowing each other.
        """
        if use_cache:
            cached = await self._cached_audio(text, voice)
            if cached:
                return cached

        lease = await self._claim_synthesis(text, voice) if use_cache else None
        if lease is False:
            # Another machine is synthesizing this exact audio right now:
            # wait for its upload instead of paying the provider twice.
            shared = await self._await_remote(text, voice)
            if shared:
                return shared
        try:
            async with self._semaphore:
                audio_data = await provider.synthesize(text, voice)
            if billing is not None and provider is self.provider:
                billing.billed_chars = len(text)

            # Apply volume boost (normalize + extra boost for max loudness)
            audio_data = boost_volume(audio_data)

            # Cache result (cache the boosted version)
            if use_cache:
                await self._store_audio(text, voice, audio_data)
        finally:
            if isinstance(lease, tuple):
                await self._release_synthesis(*lease)

        return audio_data

    # ── #207.20: shared L2 in R2 + cross-machine single-flight ────────────

    def _remote_key(self, text: str, voice: str) -> str:
        return f"questions/{self.cache._hash(text, voice)}.opus"

    def _remote_static_key(self, result: str, variant: int) -> str:
        return f"static/{self.cache._static_path(result, variant).name}"

    async def _cached_audio(self, text: str, voice: str) -> Optional[bytes]:
        """L1 disk, else R2 (refilling L1)."""
        cached = self.cache.get(text, voice)
        if cached or self.remote is None:
            return cached
        remote = await self.remote.get(self._remote_key(text, voice))
        if remote:
            self.cache.set(text, voice, remote)
        return remote

    async def _store_audio(self, text: str, voice: str, audio: bytes) -> None:
        self.cache.set(text, voice, audio)
        if self.remote is not None:
            await self.remote.put(self._remote_key(text, voice), audio)

    async def _claim_synthesis(self, text: str, voice: str):
        """(name, holder) when this machine may synthesize, False when another
        machine already is, None when there is nothing to coordinate (no
        shared store, or the lease table is unreachable: synthesize)."""
        if self.leases is None or self.remote is None:
            return None
        from ..coordination.leases import new_holder

        name = f"tts:{self.cache._hash(text, voice)}"
        holder = new_holder()
        try:
            if await self.leases.try_acquire(name, holder, TTS_LEASE_TTL_S):
                return (name, holder)
            return False
        except Exception as e:  # noqa: BLE001 — coordination is best effort
            logger.warning("TTS lease unavailable, synthesizing: %s", e)
            return None

    async def _release_synthesis(self, name: str, holder: str) -> None:
        try:
            await self.leases.release(name, holder)
        except Exception:  # noqa: BLE001 — it expires on its own
            logger.warning("TTS lease release failed for %s", name)

    async def _await_remote(self, text: str, voice: str) -> Optional[bytes]:
        """Poll R2 for the other machine's upload; None after the wait, so the
        worst case is today's duplicate synthesis, never a silent question."""
        key = self._remote_key(text, voice)
        deadline = asyncio.get_running_loop().time() + TTS_SHARED_WAIT_S
        while asyncio.get_running_loop().time() < deadline:
            await asyncio.sleep(TTS_SHARED_POLL_S)
            audio = await self.remote.get(key)
            if audio:
                self.cache.set(text, voice, audio)
                return audio
        return None

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

        return await self._static_audio(result, variant)

    async def _static_audio(self, result: str, variant: int) -> Optional[bytes]:
        """Static clip from L1, else R2 (refilling L1)."""
        audio = self.cache.get_static_feedback(result, variant)
        if audio or self.remote is None:
            return audio
        audio = await self.remote.get(self._remote_static_key(result, variant))
        if audio:
            self.cache.set_static_feedback(result, variant, audio)
        return audio

    async def pregenerate_static_feedback(self):
        """Pre-generate all static feedback phrases.

        Called on server startup to ensure instant feedback playback. Skipped
        for phrases already on disk, so the real cost is paid once per provider
        per cache volume: ~50–125 ElevenLabs credits (0.2 credit/char on v4 Turbo) or ~$0.005 on
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
                existing = await self._static_audio(result, i)
                if existing:
                    total_skipped += 1
                    continue

                # Generate new audio
                try:
                    audio_data = await self.synthesize(
                        text=phrase,
                        use_cache=False,  # Don't cache in LRU, goes to static
                    )

                    # Store in static cache (+ the shared R2 copy, #207.20)
                    self.cache.set_static_feedback(result, i, audio_data)
                    if self.remote is not None:
                        await self.remote.put(
                            self._remote_static_key(result, i), audio_data
                        )
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
