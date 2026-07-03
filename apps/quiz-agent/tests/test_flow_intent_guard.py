"""Ghost-question guard (#66, task 77.1).

A non-answer intent (rating, difficulty change, or an unparseable utterance)
must NOT advance the session or burn a freemium question. Before the guard,
``process_answer`` fell through to the session-advance block and silently
bumped ``current_question_id`` + called ``record_question()`` — a "ghost
question" that consumed a freemium quota with no answer. These tests pin the
early-return so that regression can't come back.
"""

from unittest.mock import AsyncMock, MagicMock

import pytest

from app.quiz.flow import QuizFlowService
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession
from quiz_shared.models.phase import SessionPhase


def _make_question(qid: str = "q_current") -> Question:
    return Question(
        id=qid,
        question="What is the capital of France?",
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="general",
        difficulty="medium",
    )


def _make_session() -> QuizSession:
    return QuizSession(
        session_id="s_1",
        user_id="u_1",
        phase=SessionPhase.ASKING,
        current_question_id="q_current",
        asked_question_ids=["q_current"],
        max_questions=10,
    )


def _make_flow(intents, current_question, usage_tracker):
    """Build a QuizFlowService with mocked collaborators.

    ``input_parser.parse`` returns the given intents; ``question_retriever.get``
    returns the current question. ``get_next_question`` returns a fresh question
    so that, absent the guard, the advance block *would* fire (the exact bug we
    are guarding against).
    """
    input_parser = MagicMock()
    input_parser.parse = AsyncMock(return_value=intents)

    question_retriever = MagicMock()
    question_retriever.get = MagicMock(return_value=current_question)
    question_retriever.get_next_question = MagicMock(
        return_value=_make_question("q_next")
    )

    return QuizFlowService(
        session_manager=MagicMock(),
        input_parser=input_parser,
        question_retriever=question_retriever,
        answer_evaluator=MagicMock(),
        tts_service=None,
        usage_tracker=usage_tracker,
        translation_service=None,
    )


@pytest.mark.asyncio
async def test_non_answer_intent_does_not_advance_or_record():
    """A rating intent (no evaluation) leaves the session untouched.

    Asserts the three things #66 is about: current_question_id unchanged,
    the question is NOT recorded (freemium quota not burned), and the session
    is not persisted via the advance path. The result surfaces no evaluation
    so the route can 400.
    """
    session = _make_session()
    usage_tracker = MagicMock()
    usage_tracker.record_question = AsyncMock()
    usage_tracker.check_limit = AsyncMock(return_value=(True, 5, None))

    flow = _make_flow(
        intents=[{"intent_type": "rating", "extracted_data": {"rating": 5}}],
        current_question=_make_question(),
        usage_tracker=usage_tracker,
    )

    result = await flow.process_answer(session=session, answer_text="that was fun")

    # No answer detected → the route surfaces a 400.
    assert result.evaluation is None
    assert result.next_question_dict is None
    assert result.quiz_finished is False

    # Session must NOT have advanced past the current question.
    assert session.current_question_id == "q_current"
    assert session.asked_question_ids == ["q_current"]

    # Freemium quota must NOT be burned, and no advance-path persistence.
    usage_tracker.record_question.assert_not_awaited()
    flow.session_manager.update_session.assert_not_called()


@pytest.mark.asyncio
async def test_answer_intent_still_advances():
    """Control: a real answer intent DOES advance (guard is not over-eager)."""
    session = _make_session()
    usage_tracker = MagicMock()
    usage_tracker.record_question = AsyncMock()
    usage_tracker.check_limit = AsyncMock(return_value=(True, 5, None))

    flow = _make_flow(
        intents=[{"intent_type": "answer", "extracted_data": {"answer": "Paris"}}],
        current_question=_make_question(),
        usage_tracker=usage_tracker,
    )
    flow.answer_evaluator.evaluate = AsyncMock(return_value=("correct", 1.0))

    result = await flow.process_answer(session=session, answer_text="Paris")

    assert result.evaluation is not None
    assert result.evaluation["result"] == "correct"
    assert session.current_question_id == "q_next"
    usage_tracker.record_question.assert_awaited_once()
