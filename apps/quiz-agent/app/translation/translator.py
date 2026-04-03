"""Translation service for multilingual quiz support.

Translates questions and feedback to user's preferred language using OpenAI.
"""

import logging
import os
from typing import Optional
from openai import AsyncOpenAI

logger = logging.getLogger(__name__)


# Language code to full name mapping
LANGUAGE_NAMES = {
    "en": "English",
    "sk": "Slovak",
    "cs": "Czech",
    "de": "German",
    "fr": "French",
    "es": "Spanish",
    "it": "Italian",
    "pl": "Polish",
    "hu": "Hungarian",
    "ro": "Romanian"
}


class TranslationService:
    """Service for translating quiz content to different languages.

    Uses OpenAI GPT-4 for high-quality translations that preserve
    quiz question meaning and difficulty.
    """

    def __init__(self, model: str = "gpt-4o-mini"):
        """Initialize translation service.

        Args:
            model: OpenAI model to use for translation
        """
        self.client = AsyncOpenAI(api_key=os.getenv("OPENAI_API_KEY"))
        self.model = model

    def _validate_translation(self, original: str, translated: str, target_language: str) -> str | None:
        """Validate translation quality. Returns translated text if valid, None if rejected."""
        if not translated or not translated.strip():
            logger.warning("Translation empty for '%s' → %s", original[:50], target_language)
            return None

        translated = translated.strip()

        # Minimum length check — no valid quiz question is under 15 chars
        if len(translated) < 15:
            logger.warning("Translation too short (%d chars) for '%s' → %s: '%s'",
                           len(translated), original[:50], target_language, translated)
            return None

        # Length ratio check — translation shouldn't be less than 30% of original
        ratio = len(translated) / len(original) if len(original) > 0 else 0
        if ratio < 0.3:
            logger.warning("Translation ratio too low (%.2f) for '%s' → %s: '%s'",
                           ratio, original[:50], target_language, translated)
            return None

        return translated

    async def translate_question(
        self,
        question: str,
        target_language: str,
        source_language: str = "en"
    ) -> str:
        """Translate a quiz question to target language.

        Args:
            question: Question text in source language
            target_language: ISO 639-1 code (e.g., "sk", "cs")
            source_language: ISO 639-1 code (default: "en")

        Returns:
            Translated question text
        """
        # Skip translation if already in target language
        if source_language == target_language:
            return question

        target_lang_name = LANGUAGE_NAMES.get(target_language, target_language)

        try:
            response = await self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {
                        "role": "system",
                        "content": f"You are a professional translator. Translate quiz questions to {target_lang_name}. Preserve the meaning and difficulty. Return ONLY the translated question, nothing else. The output must be a complete question sentence. Do NOT answer the question, only translate it."
                    },
                    {
                        "role": "user",
                        "content": f"Translate this quiz question to {target_lang_name}:\n\n{question}"
                    }
                ],
                temperature=0.3,  # Low temperature for consistent translations
                max_tokens=300
            )

            translated = response.choices[0].message.content.strip()

            # Remove quotes if LLM added them
            if translated.startswith('"') and translated.endswith('"'):
                translated = translated[1:-1]
            if translated.startswith("'") and translated.endswith("'"):
                translated = translated[1:-1]

            validated = self._validate_translation(question, translated, target_language)
            if validated is None:
                logger.warning("Translation validation failed, falling back to original: '%s'", question[:50])
                return question  # Fallback to original English
            return validated

        except Exception as e:
            logger.warning("Translation failed, using original: %s", e)
            return question  # Fallback to original on error

    async def translate_feedback(
        self,
        feedback: str,
        target_language: str
    ) -> str:
        """Translate feedback message to target language.

        Args:
            feedback: Feedback text (e.g., "Correct!", "Incorrect")
            target_language: ISO 639-1 code

        Returns:
            Translated feedback
        """
        # Skip translation for English
        if target_language == "en":
            return feedback

        target_lang_name = LANGUAGE_NAMES.get(target_language, target_language)

        try:
            response = await self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {
                        "role": "system",
                        "content": f"You are a professional translator. Translate short feedback messages to {target_lang_name}. Return ONLY the translation, nothing else."
                    },
                    {
                        "role": "user",
                        "content": f"Translate to {target_lang_name}: {feedback}"
                    }
                ],
                temperature=0.3,
                max_tokens=50
            )

            translated = response.choices[0].message.content.strip()

            # Remove quotes if added
            if translated.startswith('"') and translated.endswith('"'):
                translated = translated[1:-1]
            if translated.startswith("'") and translated.endswith("'"):
                translated = translated[1:-1]

            return translated

        except Exception as e:
            logger.warning("Translation failed, using original: %s", e)
            return feedback
