"""Shared serialization helpers for Question models.

Used by both api/deps.py and quiz/flow.py to avoid circular imports.
"""

from typing import Any, Dict

from quiz_shared.models.question import Question


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
    return result
