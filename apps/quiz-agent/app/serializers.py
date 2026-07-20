"""Shared serialization helpers for Question models.

Used by both api/deps.py and quiz/flow.py to avoid circular imports.
"""

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
    """Convert Question to dict with translated question text.

    Falls back silently to the original text on translation failure or when
    translation_service is None / language is "en".
    """
    question_dict = question_to_dict(question)
    if translation_service and language != "en":
        try:
            translated_text = await translation_service.translate_question(
                question=question.question,
                target_language=language,
                session_id=session_id,
            )
            question_dict["question"] = translated_text
        except Exception as e:
            logger.warning("Failed to translate question text to %s: %s", language, e)
    return question_dict
