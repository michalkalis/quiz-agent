"""Translation service for multilingual quiz support.

Translates questions and feedback to user's preferred language using OpenAI.
"""

import asyncio
import logging
import os
from collections.abc import Mapping

import sentry_sdk
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


# Process-lifetime cache cap, a soft safety valve rather than a hot-path concern (#69).
# Raised from 2000 when option values joined the cache: a question contributes its own
# SK variant (~1160 across the corpus) plus up to four option values, and every key that
# does NOT fit is re-translated on every miss for the life of the process — the cap must
# stay above the corpus, or it turns from a safety valve into a recurring bill.
CACHE_MAX_ENTRIES = 10000

# Manual refresh lever for the durable store: bump after a prompt/model improvement to
# lazily re-translate unchanged texts (old-version rows are orphaned, never served). One
# global stamp covers both prompts (#69 Decision #2). Read at call-time so tests can patch.
TRANSLATION_PROMPT_VERSION = "1"

# Attempts before falling back to the original English (#107). Was 2 — bumped to 3 after
# a founder-reported live session still leaked an untranslated question through the old
# budget.
TRANSLATION_MAX_ATTEMPTS = 3


def _strip_wrapping_quotes(text: str) -> str:
    """Drop the quote pair a model sometimes wraps a translation in."""
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    return text


def _is_language_neutral(value: str) -> bool:
    """Whether an option value has nothing to translate ("240", "1969", "12 %").

    Bare numerals are the single most common multiple-choice option shape, and
    they read the same in every language — a translation call for one buys
    nothing and would be billed once per distinct number in the corpus. Testing
    for "no letters" rather than "is a number" also covers "12 %" and "€5",
    which are equally untranslatable.
    """
    return not any(char.isalpha() for char in value)


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
        self,
        question: str,
        target_language: str,
        source_language: str = "en",
        *,
        session_id: str | None = None,
    ) -> str:
        """Translate a quiz question to target language.

        Args:
            question: Question text in source language
            target_language: ISO 639-1 code (e.g., "sk", "cs")
            source_language: ISO 639-1 code (default: "en")
            session_id: Quiz session id, used only for the fail-loud fallback message

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

        # Retry before falling back to English: a transient API error or a
        # stochastic bad completion should not leak an untranslated question to
        # the client mid-session (fallbacks are deliberately not cached).
        last_failure: dict[str, object] = {}
        for attempt in range(TRANSLATION_MAX_ATTEMPTS):
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
                    last_failure = {
                        "kind": "validation_reject",
                        "translated_len": len(translated),
                    }
                    continue
                self._maybe_store(cache_key, validated)
                return validated

            except Exception as e:
                logger.warning("Translation failed (attempt %d): %s", attempt + 1, e)
                last_failure = {"kind": "api_error", "exception": type(e).__name__}

        # Exhausted every attempt — fail loud into Sentry, not just a log line. There is
        # no local EN→SK translation corpus to calibrate the validation thresholds in
        # _validate_translation (short-length floor, 0.3 length ratio) against, so these
        # events double as the missing calibration dataset.
        original_len = len(question)
        detail_parts = [
            f"target_language={target_language!r}",
            f"kind={last_failure.get('kind')!r}",
        ]
        if last_failure.get("kind") == "api_error":
            detail_parts.append(f"exception={last_failure.get('exception')!r}")
        elif last_failure.get("kind") == "validation_reject":
            translated_len = last_failure.get("translated_len", 0)
            ratio = translated_len / original_len if original_len else 0
            detail_parts.append(f"translated_len={translated_len}")
            detail_parts.append(f"ratio={ratio:.2f}")
        detail_parts.append(f"original_len={original_len}")
        if session_id is not None:
            detail_parts.append(f"session_id={session_id!r}")
        message = (
            "Translation exhausted retries, falling back to original English "
            f"question (#107): {', '.join(detail_parts)}"
        )
        logger.warning(message)
        sentry_sdk.capture_message(message, level="warning")
        return question  # Fallback to original English (not cached)

    async def translate_options(
        self,
        options: Mapping[str, str],
        target_language: str,
        *,
        session_id: str | None = None,
    ) -> dict[str, str]:
        """Translate the values of a multiple-choice option map.

        The corpus is English-only, so a Slovak session used to show — and,
        since the read-out shipped, *speak* — "Áčko: the Eiffel Tower" inside a
        Slovak sentence, in a Slovak voice.

        Keys are never touched: "a"/"b"/"c" are the answer identifiers the
        evaluator, the iOS matcher and the spoken letter-names all key off.

        Args:
            options: ``Question.possible_answers`` ({"a": "Paris", ...})
            target_language: ISO 639-1 code
            session_id: Quiz session id, used only for the fail-loud fallback message

        Returns:
            A new map, same keys, values translated where translation applied.
            A value that could not be translated degrades to the original
            English one — a question with an English option is playable, a
            failed request is not.
        """
        if target_language == "en" or not options:
            return dict(options)

        # Concurrent, so a four-option question costs one call's latency and not
        # four on the /start hot path. Each value resolves against the cache
        # independently: "Paris" is translated once for the whole corpus, not
        # once per question that offers it.
        keys = list(options)
        results = await asyncio.gather(
            *(
                self._translate_option_value(options[key], target_language)
                for key in keys
            )
        )

        translated: dict[str, str] = {}
        failed: list[str] = []
        for key, result in zip(keys, results):
            if result is None:
                failed.append(key)
                translated[key] = options[key]
            else:
                translated[key] = result

        if failed:
            # One message per question, not per option: four failing options are
            # one incident, and a Sentry event per option would bury it.
            detail_parts = [
                f"target_language={target_language!r}",
                f"failed_keys={sorted(failed)}",
                f"option_count={len(keys)}",
            ]
            if session_id is not None:
                detail_parts.append(f"session_id={session_id!r}")
            message = (
                "Option translation failed, speaking/showing the original English "
                f"value(s): {', '.join(detail_parts)}"
            )
            logger.warning(message)
            sentry_sdk.capture_message(message, level="warning")

        return translated

    async def _translate_option_value(
        self, value: str, target_language: str
    ) -> str | None:
        """Translate one option value, or None when it must fall back to English.

        Cached under its own ``option`` kind and keyed by the value alone, which
        is what makes the cost bounded: option values are short and heavily
        repeated across the corpus ("True", "Paris", a year), so the first
        question that offers one pays for every later question that reuses it.
        """
        if _is_language_neutral(value):
            return value

        cache_key = ("option", value, target_language)
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
                        "content": f"You are a professional translator. Translate a single multiple-choice quiz answer option to {target_lang_name}. It is a short phrase, never a sentence — keep it short. Keep proper names that have no established {target_lang_name} form unchanged. Return ONLY the translation, nothing else.",
                    },
                    {
                        "role": "user",
                        "content": f"Translate to {target_lang_name}: {value}",
                    },
                ],
                temperature=0.3,
                max_tokens=40,
            )
            translated = _strip_wrapping_quotes(
                response.choices[0].message.content.strip()
            )
        except Exception as e:
            logger.warning("Option translation failed for %r: %s", value, e)
            return None

        # Deliberately NOT _validate_translation: its 0.3 length ratio rejects
        # legitimate compressions of a short phrase ("United States" → "USA").
        # The realistic failure for a phrase this short is the opposite — a
        # chatty completion ("The Slovak translation of 'Paris' is …") — so the
        # guard is against a value that grew, plus the empty completion.
        if not translated or len(translated) > 3 * len(value) + 20:
            logger.warning(
                "Option translation rejected for %r → %s: %r",
                value,
                target_language,
                translated,
            )
            return None

        self._maybe_store(cache_key, translated)
        return translated

    async def translate_feedback(
        self,
        feedback: str,
        target_language: str,
        *,
        session_id: str | None = None,
    ) -> str:
        """Translate feedback message to target language.

        Args:
            feedback: Feedback text (e.g., "Correct!", "Incorrect")
            target_language: ISO 639-1 code
            session_id: Quiz session id, used only for the fail-loud fallback message

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
            detail_parts = [
                f"target_language={target_language!r}",
                f"exception={type(e).__name__!r}",
                f"feedback_len={len(feedback)}",
            ]
            if session_id is not None:
                detail_parts.append(f"session_id={session_id!r}")
            message = (
                "Feedback translation failed, falling back to original (#107): "
                f"{', '.join(detail_parts)}"
            )
            logger.warning(message)
            sentry_sdk.capture_message(message, level="warning")
            return feedback  # Fallback to original (not cached)
