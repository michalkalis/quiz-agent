"""Voice transcription service (OpenAI gpt-transcribe, the only answer recogniser).

Converts audio files to text for voice-based quiz interaction. #208.1: replaying
the 2026-10-16 car-test recordings, ElevenLabs Scribe v2 heard nothing or
nonsense where gpt-transcribe primed with the question heard the answer, so
Scribe left the answer path (it was primary since #184; TTS stays ElevenLabs).
"""

import asyncio
import logging
from typing import Optional, BinaryIO
from dataclasses import dataclass

import openai

from quiz_shared.llm import factory as llm_factory

from quiz_shared.utils.text_normalization import normalize_text

from ..config import get_settings
from ..quiz.errors import InvalidSubmission

logger = logging.getLogger(__name__)


# Known Whisper hallucination patterns (common outputs on silence/noise)
HALLUCINATION_PATTERNS = [
    "thank you",
    "thanks for watching",
    "thanks for listening",
    "thank you for watching",
    "thank you for listening",
    "bye",
    "bye bye",
    "goodbye",
    "see you",
    "please subscribe",
    "like and subscribe",
    "music",
    "[music]",
    "(music)",
    "you",
    "...",
]


# #208.1: a dropped connection, 429 or 5xx is retried once after this pause;
# anything else (bad request, auth) would fail the same way again.
TRANSIENT_ERRORS = (
    openai.APIConnectionError,  # includes APITimeoutError
    openai.RateLimitError,
    openai.InternalServerError,
)
TRANSIENT_RETRY_BACKOFF_S = 0.3

# #204.2: a sampled decoding is a different hypothesis of the same audio
# (gpt-transcribe accepts `temperature`, checked against the API 2026-10-16).
RETRY_TEMPERATURE = 0.8

# Keyword hygiene for gpt-transcribe `keywords` (kept from the Scribe limits,
# #184): these characters and line breaks make the API reject the request.
KEYTERM_MAX_COUNT = 1000
KEYTERM_MAX_CHARS = 49
KEYTERM_MAX_WORDS = 5
KEYTERM_FORBIDDEN_CHARS = "<>{}[]"


def sanitize_keyterms(keyterms: Optional[list[str]]) -> list[str]:
    """Drop terms the API would reject, so one bad option never 400s the call."""
    cleaned: list[str] = []
    seen: set[str] = set()
    for raw in keyterms or []:
        if not raw:
            continue
        term = raw
        for ch in KEYTERM_FORBIDDEN_CHARS:
            term = term.replace(ch, " ")
        term = " ".join(term.split())
        if not term:
            continue
        if len(term.split(" ")) > KEYTERM_MAX_WORDS:
            continue
        if len(term) > KEYTERM_MAX_CHARS:
            continue
        key = term.lower()
        if key in seen:
            continue
        seen.add(key)
        cleaned.append(term)
        if len(cleaned) >= KEYTERM_MAX_COUNT:
            break
    return cleaned


@dataclass
class TranscriptionResult:
    """Result of audio transcription with confidence metrics.

    Attributes:
        text: Transcribed text
        language: Detected language code (ISO 639-1)
        no_speech_prob: Probability segment has no speech (0-1, higher = likely silence)
        avg_logprob: Average confidence (-0.5 to 0 good, < -1 low confidence)
        duration: Audio duration in seconds
    """

    text: str
    language: Optional[str]
    no_speech_prob: float
    avg_logprob: float
    duration: float

    def is_valid(self, min_chars: int = 2) -> bool:
        """Check if transcription passes quality thresholds.

        Args:
            min_chars: Shortest text that counts as an answer. 2 by default; the
                voice route passes 1 when the text names an MCQ option ("C").

        Returns:
            True if transcription appears to be valid speech, False otherwise
        """
        # Empty or very short text
        if not self.text or len(self.text.strip()) < min_chars:
            return False

        # High probability of no speech (> 0.8 = very likely silence)
        # Relaxed from 0.6 to avoid rejecting valid speech in noisy environments
        if self.no_speech_prob > 0.8:
            return False

        # Very low confidence (< -1.5 = severely garbled)
        # Relaxed from -1.0 to accept short answers and accented speech
        if self.avg_logprob < -1.5:
            return False

        # Check for known hallucination patterns
        text_lower = self.text.lower().strip()
        for pattern in HALLUCINATION_PATTERNS:
            if text_lower == pattern or text_lower == pattern + ".":
                return False

        return True

    def get_rejection_reason(self, min_chars: int = 2) -> Optional[str]:
        """Get human-readable reason why transcription was rejected.

        Returns:
            Rejection reason string, or None if valid
        """
        if not self.text or len(self.text.strip()) < min_chars:
            return "empty_transcription"

        if self.no_speech_prob > 0.8:
            return f"no_speech_detected (prob={self.no_speech_prob:.2f})"

        if self.avg_logprob < -1.5:
            return f"low_confidence (logprob={self.avg_logprob:.2f})"

        text_lower = self.text.lower().strip()
        for pattern in HALLUCINATION_PATTERNS:
            if text_lower == pattern or text_lower == pattern + ".":
                return f"hallucination_pattern ('{pattern}')"

        return None


class VoiceTranscriber:
    """Transcribes audio files to text using the OpenAI transcription API.

    Supports multiple audio formats:
    - mp3, mp4, mpeg, mpga, m4a, wav, webm

    Features:
    - High-quality transcription
    - Language detection
    - Fast processing
    - Format flexibility
    """

    SUPPORTED_FORMATS = {"mp3", "mp4", "mpeg", "mpga", "m4a", "wav", "webm", "ogg"}

    # #193: cap well under Whisper's 25 MB so one upload can't buy minutes of
    # STT. iOS hard-stops an answer at 15 s and sends 16-bit mono WAV; even
    # its 20 s buffer at a 48 kHz hardware rate is ~1.9 MB (legacy m4a ~60 KB).
    MAX_FILE_SIZE = 5 * 1024 * 1024

    def __init__(self, model: Optional[str] = None, language: Optional[str] = None):
        """Initialize voice transcriber.

        Args:
            model: OpenAI transcription model (default: settings.stt_model).
                   Set to "whisper-1" to roll back to the pre-#184 behaviour.
            language: ISO 639-1 language code (e.g., "en", "es")
                     If None, auto-detect language
        """
        # OpenAI transcription is direct-only: OpenRouter does not serve it (issue #53).
        # #208.1: the SDK's own retries are off — one retry with a short pause
        # is done here, so a provider hiccup costs ~0.3 s, not up to 8 s.
        self.client = llm_factory.openai_client(async_=True, direct=True).with_options(
            max_retries=0
        )
        self.model = model or get_settings().stt_model
        self.language = language

    async def transcribe(
        self,
        audio_file: BinaryIO,
        filename: str,
        prompt: Optional[str] = None,
        language: Optional[str] = None,
        keyterms: Optional[list[str]] = None,
    ) -> TranscriptionResult:
        """Transcribe audio file to text with confidence metrics.

        Args:
            audio_file: Audio file binary stream
            filename: Original filename (for format detection)
            prompt: Optional context to guide transcription
            language: Optional ISO 639-1 language code for this request
                     Overrides instance language if provided
            keyterms: Words the recogniser should be biased toward (MCQ option
                     texts); sent as gpt-transcribe `keywords`.

        Returns:
            TranscriptionResult with text, language, and confidence metrics

        Raises:
            InvalidSubmission: If file format not supported or file too large
                (#148 — a typed client fault the submit routes map to a 400)

        Example:
            >>> transcriber = VoiceTranscriber()
            >>> with open("answer.mp3", "rb") as f:
            ...     result = await transcriber.transcribe(f, "answer.mp3")
            >>> print(result.text)
            'Paris'
            >>> print(result.is_valid())
            True
        """
        # Validate file format
        file_ext = self._get_file_extension(filename)
        if file_ext not in self.SUPPORTED_FORMATS:
            raise InvalidSubmission(
                f"Unsupported audio format: {file_ext}. "
                f"Supported: {', '.join(self.SUPPORTED_FORMATS)}"
            )

        # Validate file size
        audio_file.seek(0, 2)  # Seek to end
        file_size = audio_file.tell()
        audio_file.seek(0)  # Reset to beginning

        if file_size > self.MAX_FILE_SIZE:
            raise InvalidSubmission(
                f"File too large: {file_size / 1024 / 1024:.1f} MB. "
                f"Maximum: {self.MAX_FILE_SIZE / 1024 / 1024} MB"
            )

        effective_language = language or self.language

        try:
            result = await self._transcribe_retrying(
                audio_file=audio_file,
                filename=filename,
                prompt=prompt,
                language=effective_language,
                keyterms=keyterms,
            )
            if not result.text and prompt:
                # #208.1: primed with the question, gpt-transcribe now and then
                # returns nothing for a clearly spoken answer that the unprimed
                # decoding hears (2026-10-16 replay: "Reset hesla", "Harper's
                # Bazaar"). One more call on an empty clip is cheaper than the
                # player having to answer again.
                audio_file.seek(0)
                result = await self._transcribe_retrying(
                    audio_file=audio_file,
                    filename=filename,
                    prompt=None,
                    language=effective_language,
                    keyterms=keyterms,
                )
        except Exception as e:
            raise RuntimeError(f"Transcription failed: {str(e)}")

        logger.info(
            # #193: length only — the player's words stay out of logs.
            "Transcribed provider=openai:%s chars=%d no_speech=%.3f logprob=%.3f",
            self.model,
            len(result.text),
            result.no_speech_prob,
            result.avg_logprob,
        )
        return result

    async def _transcribe_retrying(self, **kwargs) -> TranscriptionResult:
        """One OpenAI transcription, retried once on a transient failure (#208.1)."""
        try:
            return await self._transcribe_openai(**kwargs)
        except TRANSIENT_ERRORS as e:
            logger.warning(
                "Transcription transient failure, retrying once: %s", type(e).__name__
            )
        await asyncio.sleep(TRANSIENT_RETRY_BACKOFF_S)
        kwargs["audio_file"].seek(0)
        return await self._transcribe_openai(**kwargs)

    async def _transcribe_openai(
        self,
        audio_file: BinaryIO,
        filename: str,
        prompt: Optional[str],
        language: Optional[str],
        keyterms: Optional[list[str]] = None,
        temperature: Optional[float] = None,
    ) -> TranscriptionResult:
        # `verbose_json` (and the per-segment no_speech_prob / avg_logprob that
        # is_valid() leans on) is a whisper-1-only response format; the newer
        # transcription models return plain json and no confidence at all, so
        # their results are neutral on those two thresholds.
        is_whisper = self.model.startswith("whisper")
        params = {
            "model": self.model,
            "file": (filename, audio_file),
            "response_format": "verbose_json" if is_whisper else "json",
        }
        if prompt:
            params["prompt"] = prompt
        if temperature is not None:
            params["temperature"] = temperature
        if self.model.startswith("gpt-transcribe"):
            # #204.1: gpt-transcribe takes `languages` (array) INSTEAD of
            # `language` ("Don't send both"); the SDK has no typed argument for
            # either it or `keywords`, so both go through extra_body.
            extra: dict = {}
            if language:
                extra["languages"] = [language]
            # The sanitiser strips `<`, `>` and folds line breaks, which are
            # what make this API reject the request.
            keywords = sanitize_keyterms(keyterms)
            if keywords:
                extra["keywords"] = keywords
            if extra:
                params["extra_body"] = extra
        elif language:
            params["language"] = language

        response = await self.client.audio.transcriptions.create(**params)

        text = response.text.strip()

        if not is_whisper:
            return TranscriptionResult(
                text=text,
                language=getattr(response, "language", None),
                no_speech_prob=0.0,
                avg_logprob=0.0,
                duration=0.0,
            )

        detected_language = getattr(response, "language", None)
        duration = getattr(response, "duration", 0.0) or 0.0

        segments = getattr(response, "segments", None)
        no_speech_prob = 0.0
        avg_logprob = 0.0

        if segments and len(segments) > 0:
            total_no_speech = sum(
                getattr(seg, "no_speech_prob", 0.0) or 0.0 for seg in segments
            )
            total_logprob = sum(
                getattr(seg, "avg_logprob", 0.0) or 0.0 for seg in segments
            )
            no_speech_prob = total_no_speech / len(segments)
            avg_logprob = total_logprob / len(segments)
        else:
            logger.warning(
                "No segment data in Whisper response, falling back to permissive defaults"
            )

        return TranscriptionResult(
            text=text,
            language=detected_language,
            no_speech_prob=no_speech_prob,
            avg_logprob=avg_logprob,
            duration=duration,
        )

    @staticmethod
    def quiz_prompt(current_question: Optional[str] = None) -> str:
        """Context prompt for the recogniser: the question, never its answer."""
        prompt = "Quiz answer. "
        if current_question:
            prompt += f"Question: {current_question}. "
        prompt += "Expected: short answers, place names, proper nouns, numbers."
        return prompt

    async def transcribe_with_quiz_context(
        self,
        audio_file: BinaryIO,
        filename: str,
        current_question: Optional[str] = None,
        language: Optional[str] = None,
        keyterms: Optional[list[str]] = None,
    ) -> TranscriptionResult:
        """Transcribe audio with quiz-specific context.

        Provides better accuracy by giving Whisper context about
        the quiz domain (names, places, technical terms).

        Args:
            audio_file: Audio file binary stream
            filename: Original filename
            current_question: Current quiz question for context
            language: Optional ISO 639-1 language code for this request
                     Overrides instance language if provided

        Returns:
            TranscriptionResult with text, language, and confidence metrics

        Example:
            >>> result = await transcriber.transcribe_with_quiz_context(
            ...     audio_file,
            ...     "answer.mp3",
            ...     "What is the capital of France?"
            ... )
            >>> print(result.text)
            'Paris, but too easy'
            >>> print(result.is_valid())
            True
        """
        return await self.transcribe(
            audio_file=audio_file,
            filename=filename,
            prompt=self.quiz_prompt(current_question),
            language=language,
            keyterms=keyterms,
        )

    async def transcribe_avoiding_rejected(
        self,
        audio_file: BinaryIO,
        filename: str,
        first: TranscriptionResult,
        rejected: set[str],
        language: Optional[str],
        keyterms: list[str],
        prompt: Optional[str] = None,
        min_chars: int = 2,
    ) -> tuple[TranscriptionResult, int]:
        """Re-recognise a clip whose transcript the player already rejected (#204.2).

        ``rejected`` holds ``normalize_text``-ed transcripts. If ``first`` is not
        among them it is returned untouched (0 extra calls). Otherwise at most
        two other gpt-transcribe decodings are tried (#208.1) — without the
        question prompt, then sampled at ``RETRY_TEMPERATURE`` — with the same
        ``keyterms`` as the first pass (never the answer); the first valid one
        that is not a rejected transcript wins, else ``first`` comes back.
        Returns (result, extra_calls). Only counts are logged (#193 privacy).
        """
        if normalize_text(first.text) not in rejected:
            return first, 0

        steps = (
            ("no_prompt", {"prompt": None}),
            ("sampled", {"prompt": prompt, "temperature": RETRY_TEMPERATURE}),
        )
        attempts = 0
        for step, overrides in steps:
            attempts += 1
            audio_file.seek(0)
            try:
                candidate = await self._transcribe_openai(
                    audio_file=audio_file,
                    filename=filename,
                    language=language,
                    keyterms=keyterms,
                    **overrides,
                )
            except Exception as e:
                logger.warning(
                    "Retry recognition step=%s failed: %s", step, type(e).__name__
                )
                continue
            if candidate.is_valid(min_chars=min_chars) and (
                normalize_text(candidate.text) not in rejected
            ):
                logger.info(
                    "Retry recognition avoided rejected transcript attempts=%d",
                    attempts,
                )
                return candidate, attempts
        logger.info("Retry recognition kept original transcript attempts=%d", attempts)
        return first, attempts

    def _get_file_extension(self, filename: str) -> str:
        """Extract file extension from filename.

        Args:
            filename: Filename with extension

        Returns:
            Lowercase file extension without dot
        """
        if "." not in filename:
            return ""

        return filename.rsplit(".", 1)[1].lower()

    def is_supported_format(self, filename: str) -> bool:
        """Check if file format is supported.

        Args:
            filename: Filename with extension

        Returns:
            True if format is supported
        """
        ext = self._get_file_extension(filename)
        return ext in self.SUPPORTED_FORMATS
