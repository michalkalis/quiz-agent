"""Voice transcription service using OpenAI Whisper API.

Converts audio files to text for voice-based quiz interaction.
"""

from typing import Optional, BinaryIO
from dataclasses import dataclass
from openai import AsyncOpenAI
import os


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

    def is_valid(self) -> bool:
        """Check if transcription passes quality thresholds.

        Returns:
            True if transcription appears to be valid speech, False otherwise
        """
        # Empty or very short text
        if not self.text or len(self.text.strip()) < 2:
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

    def get_rejection_reason(self) -> Optional[str]:
        """Get human-readable reason why transcription was rejected.

        Returns:
            Rejection reason string, or None if valid
        """
        if not self.text or len(self.text.strip()) < 2:
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
    """Transcribes audio files to text using Whisper API.

    Supports multiple audio formats:
    - mp3, mp4, mpeg, mpga, m4a, wav, webm

    Features:
    - High-quality transcription
    - Language detection
    - Fast processing
    - Format flexibility
    """

    SUPPORTED_FORMATS = {
        "mp3", "mp4", "mpeg", "mpga", "m4a", "wav", "webm", "ogg"
    }

    MAX_FILE_SIZE = 25 * 1024 * 1024  # 25 MB (Whisper API limit)

    def __init__(
        self,
        model: str = "whisper-1",
        language: Optional[str] = None
    ):
        """Initialize voice transcriber.

        Args:
            model: Whisper model (default: whisper-1)
            language: ISO 639-1 language code (e.g., "en", "es")
                     If None, auto-detect language
        """
        self.client = AsyncOpenAI(api_key=os.getenv("OPENAI_API_KEY"))
        self.model = model
        self.language = language

    async def transcribe(
        self,
        audio_file: BinaryIO,
        filename: str,
        prompt: Optional[str] = None,
        language: Optional[str] = None
    ) -> TranscriptionResult:
        """Transcribe audio file to text with confidence metrics.

        Args:
            audio_file: Audio file binary stream
            filename: Original filename (for format detection)
            prompt: Optional context to guide transcription
            language: Optional ISO 639-1 language code for this request
                     Overrides instance language if provided

        Returns:
            TranscriptionResult with text, language, and confidence metrics

        Raises:
            ValueError: If file format not supported or file too large

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
            raise ValueError(
                f"Unsupported audio format: {file_ext}. "
                f"Supported: {', '.join(self.SUPPORTED_FORMATS)}"
            )

        # Validate file size
        audio_file.seek(0, 2)  # Seek to end
        file_size = audio_file.tell()
        audio_file.seek(0)  # Reset to beginning

        if file_size > self.MAX_FILE_SIZE:
            raise ValueError(
                f"File too large: {file_size / 1024 / 1024:.1f} MB. "
                f"Maximum: {self.MAX_FILE_SIZE / 1024 / 1024} MB"
            )

        # Transcribe with Whisper API
        try:
            # Prepare request parameters
            params = {
                "model": self.model,
                "file": (filename, audio_file),
                "response_format": "verbose_json"
            }

            # Use per-request language if provided, otherwise fall back to instance language
            effective_language = language or self.language
            if effective_language:
                params["language"] = effective_language

            # Add prompt for context (improves accuracy)
            if prompt:
                params["prompt"] = prompt

            # Call Whisper API
            response = await self.client.audio.transcriptions.create(**params)

            # Extract text and detected language
            text = response.text.strip()
            detected_language = getattr(response, "language", None)
            duration = getattr(response, "duration", 0.0) or 0.0

            # Extract confidence metrics from segments (verbose_json format)
            segments = getattr(response, "segments", None)
            no_speech_prob = 0.0
            avg_logprob = 0.0

            if segments and len(segments) > 0:
                # Average metrics across all segments
                total_no_speech = sum(
                    getattr(seg, "no_speech_prob", 0.0) or 0.0 for seg in segments
                )
                total_logprob = sum(
                    getattr(seg, "avg_logprob", 0.0) or 0.0 for seg in segments
                )
                no_speech_prob = total_no_speech / len(segments)
                avg_logprob = total_logprob / len(segments)

                print(f"DEBUG [transcribe]: segments={len(segments)}, "
                      f"no_speech_prob={no_speech_prob:.3f}, "
                      f"avg_logprob={avg_logprob:.3f}, "
                      f"duration={duration:.2f}s")
            else:
                # Fallback: no segment data available (shouldn't happen with verbose_json)
                print(f"⚠️ WARNING [transcribe]: No segment data in Whisper response, "
                      f"falling back to permissive defaults")

            return TranscriptionResult(
                text=text,
                language=detected_language,
                no_speech_prob=no_speech_prob,
                avg_logprob=avg_logprob,
                duration=duration
            )

        except Exception as e:
            raise RuntimeError(f"Transcription failed: {str(e)}")

    async def transcribe_with_quiz_context(
        self,
        audio_file: BinaryIO,
        filename: str,
        current_question: Optional[str] = None,
        language: Optional[str] = None
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
        # Build context prompt
        prompt = "Quiz answer. "
        if current_question:
            prompt += f"Question: {current_question}. "
        prompt += "Expected: short answers, place names, proper nouns, numbers."

        return await self.transcribe(
            audio_file=audio_file,
            filename=filename,
            prompt=prompt,
            language=language
        )

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
