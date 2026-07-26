"""Shared serialization helpers for Question models.

Used by both api/deps.py and quiz/flow.py to avoid circular imports.
"""

import asyncio
import logging
from typing import Any, Dict

from quiz_shared.models.question import PublicQuestion, Question

logger = logging.getLogger(__name__)


def question_to_dict(question: Question) -> Dict[str, Any]:
    """Convert Question to dict for API response (no correct_answer).

    The shape is owned by ``quiz_shared.models.question.PublicQuestion`` — its
    custom serializer reproduces the legacy hand-built dict exactly (fixed keys
    always present, media/extra keys omitted when unset), so iOS decoding is
    unchanged while OpenAPI now sees a typed contract.
    """
    return PublicQuestion.from_question(question).model_dump()


async def question_to_dict_translated(
    question: Question,
    language: str,
    translation_service=None,
    *,
    session_id: str | None = None,
) -> Dict[str, Any]:
    """Convert Question to dict with translated question text and option values.

    This dict is the ONE projection the client renders and the TTS read-out
    speaks (see ``tts.question_speech.build_question_speech_text``), so the
    options are translated here rather than at either consumer — translating at
    one of them would make a Slovak session show one set of choices and say
    another.

    Falls back silently to the original text on translation failure or when
    translation_service is None / language is "en".
    """
    question_dict = question_to_dict(question)
    if not translation_service or language == "en":
        return question_dict

    options = question_dict.get("possible_answers")
    # Concurrent: the option values are short and their translations are cached
    # per value, but a Slovak /start must not pay question-latency + option-
    # latency back to back on a hot path the founder already reports as slow.
    translated_text, translated_options = await asyncio.gather(
        translation_service.translate_question(
            question=question.question,
            target_language=language,
            session_id=session_id,
        ),
        translation_service.translate_options(
            options or {},
            language,
            session_id=session_id,
        ),
        return_exceptions=True,
    )

    if isinstance(translated_text, BaseException):
        logger.warning(
            "Failed to translate question text to %s: %s", language, translated_text
        )
    else:
        question_dict["question"] = translated_text

    if isinstance(translated_options, BaseException):
        logger.warning(
            "Failed to translate options to %s: %s", language, translated_options
        )
    elif options:
        question_dict["possible_answers"] = translated_options

    return question_dict
