"""Shared serialization helpers for Question models.

Used by both api/deps.py and quiz/flow.py to avoid circular imports.
"""

import logging
from typing import Any, Dict

import sentry_sdk
from quiz_shared.models.question import PublicQuestion, Question

logger = logging.getLogger(__name__)


def _flag_language_dependent(
    question: Question, language: str, session_id: str | None
) -> None:
    """Fail loud when a language-bound question reaches a non-English session (#128).

    ``language_dependent`` marks a fact that only holds as an English lexical
    convention ("a murder of crows"): translating the text literally keeps the
    sentence fluent but makes the answer false. Retrieval already filters these
    rows out for non-English sessions, so reaching this point means the row was
    mistagged upstream or came through the custom-pack path, which drops the
    filter by design.

    Deliberately observational, not a refusal: serving must not break mid-quiz,
    and both alternatives (skip the question, or serve raw English) are worse
    for the player than a fluent-but-wrong question. So this mirrors the #107
    Sentry pattern — capture the event, then serve exactly as before.
    """
    detail_parts = [
        f"question_id={question.id!r}",
        f"target_language={language!r}",
        f"category={question.category!r}",
        f"pack_id={question.pack_id!r}",
    ]
    if session_id is not None:
        detail_parts.append(f"session_id={session_id!r}")
    message = (
        "Serving a language_dependent question into a non-English session; its "
        f"fact may not survive translation (#128): {', '.join(detail_parts)}"
    )
    logger.warning(message)
    sentry_sdk.capture_message(message, level="warning")


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

    A ``language_dependent`` question in a non-English session is still served
    (see ``_flag_language_dependent``), but it is reported to Sentry first.
    """
    if language != "en" and question.language_dependent:
        _flag_language_dependent(question, language, session_id)
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
