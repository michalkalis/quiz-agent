"""Shared serialization helpers for Question models.

Used by both api/deps.py and quiz/flow.py to avoid circular imports.
"""

import logging
from typing import Any, Dict, Optional, Tuple

import sentry_sdk
from quiz_shared.models.question import PublicQuestion, Question
from quiz_shared.models.session import QuizSession
from quiz_shared.utils.text_normalization import normalize_text

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


def correct_option_key(question: Question) -> Optional[str]:
    """Resolve a MCQ's correct answer to its option key, against ENGLISH options.

    The corpus stores ``correct_answer`` either as a key ("b") or as the option
    text ("Paris"). Once the options are translated, matching the stored English
    text against Slovak options is impossible — so the key is resolved here, at
    serve time, while both sides are still English. Everything downstream then
    compares keys (see ``AnswerEvaluator._evaluate_mcq``).

    Returns None for non-MCQ questions and for MCQ rows whose stored answer
    matches no option (a data defect the evaluator already treats as incorrect).
    """
    options = question.possible_answers
    if not options:
        return None
    correct = question.correct_answer
    if isinstance(correct, list):
        correct = correct[0] if correct else ""
    correct = str(correct)
    if correct in options:
        return correct
    for key, value in options.items():
        if normalize_text(correct) == normalize_text(value):
            return key
    return None


def _correct_answer_text(question: Question) -> str:
    correct = question.correct_answer
    if isinstance(correct, list):
        correct = correct[0] if correct else ""
    return str(correct)


async def build_question_translation(
    question: Question,
    language: str,
    translation_service=None,
    *,
    session_id: str | None = None,
) -> Optional[Dict[str, Any]]:
    """Translate the whole question payload in one LLM call (#132 track D).

    Returns a *translation record* — the single source of truth for what the
    player is shown, what their answer is matched against, and what the result
    screen says. Returns None (serve English) for English sessions, when no
    translation service is wired, or when translation failed after its retries.
    """
    if language == "en" or not translation_service:
        return None

    payload: Dict[str, Any] = {"question": question.question}
    if question.possible_answers:
        payload["options"] = dict(question.possible_answers)
    if question.explanation:
        payload["explanation"] = question.explanation
    if question.headline_answer:
        payload["headline_answer"] = question.headline_answer

    # MCQ: the answer text the player sees comes from the translated options, so
    # it is not translated twice. Only a free-text answer needs its own field.
    correct_key = correct_option_key(question)
    correct_text = _correct_answer_text(question)
    if correct_key is None and correct_text:
        payload["correct_answer"] = correct_text

    try:
        translated = await translation_service.translate_question_payload(
            payload, language, session_id=session_id
        )
    except Exception as e:
        logger.warning("Failed to translate question payload to %s: %s", language, e)
        return None
    if not translated:
        return None

    options = translated.get("options") or None
    if correct_key and options:
        correct_display = options.get(correct_key, correct_text)
    else:
        correct_display = translated.get("correct_answer") or correct_text

    return {
        "question_id": question.id,
        "language": language,
        "question": translated["question"],
        "possible_answers": options,
        "explanation": translated.get("explanation"),
        "headline_answer": translated.get("headline_answer"),
        "correct_answer": correct_display,
        "correct_answer_key": correct_key,
    }


def apply_question_translation(
    question_dict: Dict[str, Any], record: Optional[Dict[str, Any]]
) -> Dict[str, Any]:
    """Overlay a translation record onto a public question dict (in place).

    Keys and structure are untouched — only the language of the values changes,
    so the OpenAPI contract is unaffected.
    """
    if not record:
        return question_dict
    question_dict["question"] = record["question"]
    if record.get("possible_answers"):
        question_dict["possible_answers"] = dict(record["possible_answers"])
    if record.get("explanation"):
        question_dict["explanation"] = record["explanation"]
    if record.get("headline_answer"):
        question_dict["headline_answer"] = record["headline_answer"]
    return question_dict


def session_translation(
    session: QuizSession, question_id: str
) -> Optional[Dict[str, Any]]:
    """The stored translation record, but only if it is for this exact question
    and this session's current language (a language switch invalidates it)."""
    record = session.current_question_translation
    if not record:
        return None
    if record.get("question_id") != question_id:
        return None
    if record.get("language") != session.language:
        return None
    return record


def translated_question_view(
    question: Question, record: Optional[Dict[str, Any]]
) -> Question:
    """The question as the player saw it — what evaluation must score against.

    ``correct_answer`` becomes the option *key* for MCQ so the evaluator's
    key resolution still succeeds against translated option text; free-text
    questions carry the translated answer instead.
    """
    if not record:
        return question
    update: Dict[str, Any] = {"question": record["question"]}
    if record.get("possible_answers"):
        update["possible_answers"] = dict(record["possible_answers"])
    if record.get("explanation"):
        update["explanation"] = record["explanation"]
    if record.get("headline_answer"):
        update["headline_answer"] = record["headline_answer"]
    update["correct_answer"] = (
        record.get("correct_answer_key") or record["correct_answer"]
    )
    return question.model_copy(update=update)


async def translated_question_payload(
    question: Question,
    language: str,
    translation_service=None,
    *,
    session_id: str | None = None,
) -> Tuple[Dict[str, Any], Optional[Dict[str, Any]]]:
    """Serve-time entry point: ``(public payload, translation record)``.

    One LLM call covers stem + options + explanation + answer. Callers that own
    session state persist the record on the session so evaluation and the result
    screen read exactly the strings the player was shown.

    A ``language_dependent`` question in a non-English session is still served
    (see ``_flag_language_dependent``), but it is reported to Sentry first.
    """
    if language != "en" and question.language_dependent:
        _flag_language_dependent(question, language, session_id)
    question_dict = question_to_dict(question)
    record = await build_question_translation(
        question, language, translation_service, session_id=session_id
    )
    return apply_question_translation(question_dict, record), record


async def question_to_dict_translated(
    question: Question,
    language: str,
    translation_service=None,
    *,
    session_id: str | None = None,
) -> Dict[str, Any]:
    """Convert Question to a fully translated public dict (stem, options,
    explanation). Falls back silently to English on translation failure or when
    translation_service is None / language is "en"."""
    question_dict, _ = await translated_question_payload(
        question, language, translation_service, session_id=session_id
    )
    return question_dict
