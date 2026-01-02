"""Voice transcription service using OpenAI Whisper API.

Converts audio files to text for voice-based quiz interaction.
"""

from typing import Optional, BinaryIO
from openai import AsyncOpenAI
import os


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
    ) -> tuple[str, Optional[str]]:
        """Transcribe audio file to text.

        Args:
            audio_file: Audio file binary stream
            filename: Original filename (for format detection)
            prompt: Optional context to guide transcription
            language: Optional ISO 639-1 language code for this request
                     Overrides instance language if provided

        Returns:
            Tuple of (transcribed_text, language)

        Raises:
            ValueError: If file format not supported or file too large

        Example:
            >>> transcriber = VoiceTranscriber()
            >>> with open("answer.mp3", "rb") as f:
            ...     text, lang = await transcriber.transcribe(f, "answer.mp3")
            >>> print(text)
            'Paris'
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

            return text, detected_language

        except Exception as e:
            raise RuntimeError(f"Transcription failed: {str(e)}")

    async def transcribe_with_quiz_context(
        self,
        audio_file: BinaryIO,
        filename: str,
        current_question: Optional[str] = None,
        language: Optional[str] = None
    ) -> str:
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
            Transcribed text

        Example:
            >>> text = await transcriber.transcribe_with_quiz_context(
            ...     audio_file,
            ...     "answer.mp3",
            ...     "What is the capital of France?"
            ... )
            >>> print(text)
            'Paris, but too easy'
        """
        # Build context prompt
        prompt = "Quiz answer. "
        if current_question:
            prompt += f"Question: {current_question}. "
        prompt += "Expected: short answers, place names, proper nouns, numbers."

        text, _ = await self.transcribe(
            audio_file=audio_file,
            filename=filename,
            prompt=prompt,
            language=language
        )

        return text

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
