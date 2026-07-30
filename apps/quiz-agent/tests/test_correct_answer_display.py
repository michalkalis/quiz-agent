"""Adversarial audit 2026-07-30: English MCQ sessions announced the bare option
letter as the correct answer.

``_correct_answer_display`` returned ``question.correct_answer`` verbatim when
there was no serve-time translation record, and there never is one for an
English session. Most approved MCQ rows in the corpus store the answer as a bare
key ("b"), so the result screen read "The answer is b." and the feedback audio
spoke a single letter. Slovak sessions were fine because the translation path
already resolves the key through ``correct_option_key``. These tests pin that
both paths now name the option, and that non-MCQ answers are still passed
through untouched.
"""

from unittest.mock import AsyncMock, MagicMock

import pytest

from app.quiz.flow import QuizFlowService
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession
from quiz_shared.models.phase import SessionPhase

OPTIONS = {"a": "Mercury", "b": "Venus", "c": "Earth", "d": "Mars"}


def _mcq(correct_answer) -> Question:
    return Question(
        id="q_current",
        question="Which planet is hottest?",
        type="text_multichoice",
        possible_answers=OPTIONS,
        correct_answer=correct_answer,
        topic="Space",
        category="general",
        difficulty="medium",
    )


def _free_text() -> Question:
    return Question(
        id="q_current",
        question="What is the capital of France?",
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="general",
        difficulty="medium",
    )


def _make_session(language: str = "en") -> QuizSession:
    return QuizSession(
        session_id="s_1",
        phase=SessionPhase.ASKING,
        language=language,
        current_question_id="q_current",
        asked_question_ids=["q_current"],
        max_questions=10,
    )


def _make_flow(current_question: Question) -> QuizFlowService:
    input_parser = MagicMock()
    input_parser.parse = AsyncMock(
        return_value=[{"intent_type": "answer", "extracted_data": {"answer": "b"}}]
    )
    question_retriever = MagicMock()
    question_retriever.get = MagicMock(return_value=current_question)
    question_retriever.get_next_question = MagicMock(return_value=None)

    flow = QuizFlowService(
        session_manager=MagicMock(),
        input_parser=input_parser,
        question_retriever=question_retriever,
        answer_evaluator=MagicMock(),
        tts_service=None,
        usage_tracker=None,
        translation_service=None,
    )
    flow.answer_evaluator.evaluate = AsyncMock(return_value=("correct", 1.0))
    return flow


@pytest.mark.asyncio
async def test_english_mcq_answer_stored_as_key_reports_the_option_text():
    """The corpus stores most MCQ answers as a bare key — the player must be told
    "Venus", never "b"."""
    flow = _make_flow(_mcq("b"))

    result = await flow.process_answer(session=_make_session(), answer_text="b")

    assert result.evaluation["correct_answer"] == "Venus"


@pytest.mark.asyncio
async def test_english_mcq_answer_stored_as_text_is_unchanged():
    """Rows that already store the option text must keep reporting it (the key
    resolution must not mangle the newer pipeline's shape)."""
    flow = _make_flow(_mcq("Venus"))

    result = await flow.process_answer(session=_make_session(), answer_text="b")

    assert result.evaluation["correct_answer"] == "Venus"


@pytest.mark.asyncio
async def test_non_mcq_answer_is_passed_through_raw():
    """Free-text answers have no options to resolve — the stored value IS the
    answer and must survive verbatim."""
    flow = _make_flow(_free_text())

    result = await flow.process_answer(session=_make_session(), answer_text="Paris")

    assert result.evaluation["correct_answer"] == "Paris"


@pytest.mark.asyncio
async def test_translation_record_still_wins():
    """A translated session already carries the option text in its record — the
    key resolution must not bypass the wording the player actually saw."""
    session = _make_session(language="sk")
    session.current_question_translation = {
        "question_id": "q_current",
        "language": "sk",
        "question": "Ktora planeta je najteplejsia?",
        "options": {"a": "Merkur", "b": "Venusa", "c": "Zem", "d": "Mars"},
        "correct_answer": "Venusa",
    }
    flow = _make_flow(_mcq("b"))

    result = await flow.process_answer(session=session, answer_text="b")

    assert result.evaluation["correct_answer"] == "Venusa"
