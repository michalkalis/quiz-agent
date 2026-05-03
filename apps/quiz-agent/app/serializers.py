"""Shared serialization helpers for Question models.

Used by both api/deps.py and quiz/flow.py to avoid circular imports.
"""

import logging
from typing import Any, Dict

from quiz_shared.models.question import Question

logger = logging.getLogger(__name__)


def question_to_dict(question: Question) -> Dict[str, Any]:
    """Convert Question to dict for API response (no correct_answer)."""
    result = {
        "id": question.id,
        "question": question.question,
        "type": question.type,
        "possible_answers": question.possible_answers,
        "difficulty": question.difficulty,
        "topic": question.topic,
        "category": question.category,
        "source_url": question.source_url,
        "source_excerpt": question.source_excerpt,
    }
    if question.media_url:
        result["media_url"] = question.media_url
    if question.image_subtype:
        result["image_subtype"] = question.image_subtype
    if question.explanation:
        result["explanation"] = question.explanation
    if question.age_appropriate:
        result["age_appropriate"] = question.age_appropriate
    # Extract model name from generation metadata for A/B testing
    if question.generation_metadata and "model" in question.generation_metadata:
        result["generated_by"] = question.generation_metadata["model"]
    return result


async def question_to_dict_translated(
    question: Question, language: str, translation_service=None
) -> Dict[str, Any]:
    """Convert Question to dict with translated question text.

    Falls back silently to the original text on translation failure or when
    translation_service is None / language is "en".
    """
    question_dict = question_to_dict(question)
    if translation_service and language != "en":
        try:
            translated_text = await translation_service.translate_question(
                question=question.question, target_language=language
            )
            question_dict["question"] = translated_text
        except Exception as e:
            logger.warning("Failed to translate question text to %s: %s", language, e)
    return question_dict
