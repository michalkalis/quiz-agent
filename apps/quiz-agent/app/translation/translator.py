"""Translation service for multilingual quiz support.

Translates questions and feedback to user's preferred language using OpenAI.
"""

import os
from typing import Optional
from openai import AsyncOpenAI


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
                        "content": f"You are a professional translator. Translate quiz questions to {target_lang_name}. Preserve the meaning and difficulty. Return ONLY the translated question, nothing else."
                    },
                    {
                        "role": "user",
                        "content": f"Translate this quiz question to {target_lang_name}:\n\n{question}"
                    }
                ],
                temperature=0.3,  # Low temperature for consistent translations
                max_tokens=200
            )

            translated = response.choices[0].message.content.strip()

            # Remove quotes if LLM added them
            if translated.startswith('"') and translated.endswith('"'):
                translated = translated[1:-1]
            if translated.startswith("'") and translated.endswith("'"):
                translated = translated[1:-1]

            return translated

        except Exception as e:
            print(f"⚠️ Translation failed, using original: {e}")
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
            print(f"⚠️ Translation failed, using original: {e}")
            return feedback
