"""Translation service for multilingual quiz support.

Translates questions and feedback to user's preferred language using OpenAI.
"""

import logging
import os

from quiz_shared.llm import factory as llm_factory

from app.translation.store import TranslationStore

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
    "ro": "Romanian",
}


# Process-lifetime cache cap. Translated corpus cardinality (~1160 SK variants) sits well
# under this, so the guard is a soft safety valve, not a hot-path concern (#69).
CACHE_MAX_ENTRIES = 2000

# Manual refresh lever for the durable store: bump after a prompt/model improvement to
# lazily re-translate unchanged texts (old-version rows are orphaned, never served). One
# global stamp covers both prompts (#69 Decision #2). Read at call-time so tests can patch.
TRANSLATION_PROMPT_VERSION = "1"


class TranslationService:
    """Service for translating quiz content to different languages.

    Uses OpenAI GPT-4 for high-quality translations that preserve
    quiz question meaning and difficulty.
    """

    def __init__(self, model: str = "gpt-4o-mini", store_url: str | None = None):
        """Initialize translation service.

        Args:
            model: OpenAI model to use for translation
            store_url: SQLAlchemy URL for the durable translation store; defaults to
                TRANSLATION_CACHE_URL env var, then sqlite under ./data (→ /data in prod)
        """
        self.client = llm_factory.openai_client(async_=True)
        self.model = llm_factory.resolve_model(model)
        # Process-lifetime cache of validated translations, keyed (kind, text, target_language).
        # TranslationService is a process-wide singleton, so this survives every request/session.
        self._cache: dict[tuple[str, str, str], str] = {}
        # Durable store: warm-load current-version rows into the dict at startup, write
        # through on each validated success. Fail-soft is mandatory — this __init__ runs
        # inside main.py's re-raising services block, so a bad /data/translations.db must
        # degrade to an empty in-memory cache, never crash-loop the app (#69 Decision #1).
        store_url = store_url or os.getenv(
            "TRANSLATION_CACHE_URL", "sqlite:///./data/translations.db"
        )
        try:
            self._store: TranslationStore | None = TranslationStore(store_url)
            self._cache = self._store.load_version(TRANSLATION_PROMPT_VERSION)
        except Exception as e:
            logger.warning(
                "Translation store unavailable (%s), degrading to in-memory cache: %s",
                store_url,
                e,
            )
            self._store = None
            self._cache = {}

    def _maybe_store(self, key: tuple[str, str, str], value: str) -> None:
        """Cache a validated translation, bounded by CACHE_MAX_ENTRIES.

        Reads the module-global cap at call-time (so a test can monkeypatch it). Once full,
        new keys stop being inserted while existing hits keep serving — provably bounded, no
        eviction bookkeeping.

        Single write-through point for the durable store. Dict insert comes FIRST and the
        durable write is best-effort: this runs inside the translate try-blocks, so a disk
        error must never propagate (it would downgrade a validated translation to the
        English fallback and skip the in-memory cache too).
        """
        if len(self._cache) < CACHE_MAX_ENTRIES:
            self._cache[key] = value
        if self._store is not None:
            kind, text, lang = key
            try:
                self._store.upsert(kind, text, lang, TRANSLATION_PROMPT_VERSION, value)
            except Exception as e:
                logger.warning(
                    "Durable translation write failed (kept in-memory): %s", e
                )

    def _validate_translation(
        self, original: str, translated: str, target_language: str
    ) -> str | None:
        """Validate translation quality. Returns translated text if valid, None if rejected."""
        if not translated or not translated.strip():
            logger.warning(
                "Translation empty for '%s' → %s", original[:50], target_language
            )
            return None

        translated = translated.strip()

        # Minimum length check — but only when the original is itself long enough
        # that a sub-15-char translation is suspicious. Short questions (e.g. T/F
        # prompts) can legitimately translate compactly; the absolute floor was
        # silently discarding valid Slovak translations and leaking English.
        if len(translated) < 15 and len(original) >= 30:
            logger.warning(
                "Translation too short (%d chars) for '%s' → %s: '%s'",
                len(translated),
                original[:50],
                target_language,
                translated,
            )
            return None

        # Length ratio check — translation shouldn't be less than 30% of original
        ratio = len(translated) / len(original) if len(original) > 0 else 0
        if ratio < 0.3:
            logger.warning(
                "Translation ratio too low (%.2f) for '%s' → %s: '%s'",
                ratio,
                original[:50],
                target_language,
                translated,
            )
            return None

        return translated

    async def translate_question(
        self, question: str, target_language: str, source_language: str = "en"
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

        cache_key = ("question", question, target_language)
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        target_lang_name = LANGUAGE_NAMES.get(target_language, target_language)

        # One retry before falling back to English: a transient API error or a
        # stochastic bad completion should not leak an untranslated question to
        # the client mid-session (fallbacks are deliberately not cached).
        for attempt in range(2):
            try:
                response = await self.client.chat.completions.create(
                    model=self.model,
                    messages=[
                        {
                            "role": "system",
                            "content": f"You are a professional translator. Translate quiz questions to {target_lang_name}. Preserve the meaning and difficulty. Return ONLY the translated question, nothing else. The output must be a complete question sentence. Do NOT answer the question, only translate it.",
                        },
                        {
                            "role": "user",
                            "content": f"Translate this quiz question to {target_lang_name}:\n\n{question}",
                        },
                    ],
                    temperature=0.3,  # Low temperature for consistent translations
                    max_tokens=300,
                )

                translated = response.choices[0].message.content.strip()

                # Remove quotes if LLM added them
                if translated.startswith('"') and translated.endswith('"'):
                    translated = translated[1:-1]
                if translated.startswith("'") and translated.endswith("'"):
                    translated = translated[1:-1]

                validated = self._validate_translation(
                    question, translated, target_language
                )
                if validated is None:
                    logger.warning(
                        "Translation validation failed (attempt %d) for '%s'",
                        attempt + 1,
                        question[:50],
                    )
                    continue
                self._maybe_store(cache_key, validated)
                return validated

            except Exception as e:
                logger.warning("Translation failed (attempt %d): %s", attempt + 1, e)

        logger.warning(
            "Translation exhausted retries, falling back to original: '%s'",
            question[:50],
        )
        return question  # Fallback to original English (not cached)

    async def translate_feedback(self, feedback: str, target_language: str) -> str:
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

        cache_key = ("feedback", feedback, target_language)
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        target_lang_name = LANGUAGE_NAMES.get(target_language, target_language)

        try:
            response = await self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {
                        "role": "system",
                        "content": f"You are a professional translator. Translate short feedback messages to {target_lang_name}. Return ONLY the translation, nothing else.",
                    },
                    {
                        "role": "user",
                        "content": f"Translate to {target_lang_name}: {feedback}",
                    },
                ],
                temperature=0.3,
                max_tokens=50,
            )

            translated = response.choices[0].message.content.strip()

            # Remove quotes if added
            if translated.startswith('"') and translated.endswith('"'):
                translated = translated[1:-1]
            if translated.startswith("'") and translated.endswith("'"):
                translated = translated[1:-1]

            self._maybe_store(cache_key, translated)
            return translated

        except Exception as e:
            logger.warning("Translation failed, using original: %s", e)
            return feedback  # Fallback to original (not cached)
