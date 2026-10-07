"""Question counter after a skip (founder bug 2026-10-07).

iOS showed "question 3/10", the player skipped, and the next question read
"2/10" — the result screen of the skipped question was one short too. The app
derived the number from the participant's ``answered_count``, which a skip
deliberately does not move (it is the scoring denominator). The session now
carries ``asked_count`` = every question served, answered or skipped, so the
counter has a source that cannot fall behind.

Contract the client builds on: a response that grades a question AND serves the
next one already counts that next one (asked_count == the next question's
number); a response that serves nothing (last question, pack still generating)
still counts only the graded question.
"""

from unittest.mock import AsyncMock, MagicMock

import pytest

from app.api.deps import session_to_response
from app.quiz.flow import QuizFlowService
from quiz_shared.models.participant import Participant
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

pytestmark = pytest.mark.asyncio


def _question(qid: str) -> Question:
    return Question(
        id=qid,
        question=f"Question {qid}?",
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="general",
        difficulty="medium",
    )


def _session_on_third_question(max_questions: int = 10) -> QuizSession:
    """Player is on question 3: two answered, the third on screen."""
    return QuizSession(
        session_id="s_counter",
        phase=SessionPhase.ASKING,
        language="en",
        current_question_id="q3",
        asked_question_ids=["q1", "q2", "q3"],
        max_questions=max_questions,
        participants=[
            Participant(participant_id="p1", display_name="Player", answered_count=2)
        ],
    )


def _flow(next_question=None, pack_generating: bool = False) -> QuizFlowService:
    retriever = MagicMock()
    retriever.get = AsyncMock(side_effect=lambda qid: _question(qid))
    retriever.get_next_question = AsyncMock(return_value=next_question)
    retriever.pack_is_generating = AsyncMock(return_value=pack_generating)
    return QuizFlowService(
        session_manager=MagicMock(),
        input_parser=MagicMock(),
        question_retriever=retriever,
        answer_evaluator=MagicMock(),
        tts_service=None,
        usage_tracker=None,
        translation_service=None,
    )


async def test_skip_counts_as_an_asked_question_though_not_an_answered_one():
    """The bug itself: after skipping question 3 the next question is number 4,
    even though the player has still answered only two."""
    session = _session_on_third_question()
    flow = _flow(next_question=_question("q4"))

    result = await flow.process_answer(session=session, answer_text="skip")

    assert result.evaluation.result == "skipped"
    assert result.next_question_dict["id"] == "q4"
    wire = session_to_response(session)
    assert wire.asked_count == 4  # number of the question just served
    # Score semantics unchanged: a skip is still not an answer.
    assert wire.participants[0].answered_count == 2


async def test_skip_of_last_question_counts_only_the_skipped_question():
    """No next question is served on the last one, so the result screen's
    number (the skipped question's) is asked_count itself — 10/10, not 9/10."""
    session = QuizSession(
        session_id="s_counter",
        phase=SessionPhase.ASKING,
        language="en",
        current_question_id="q10",
        asked_question_ids=[f"q{i}" for i in range(1, 11)],
        max_questions=10,
    )
    flow = _flow()

    result = await flow.process_answer(session=session, answer_text="skip")

    assert result.quiz_finished
    assert session_to_response(session).asked_count == 10


async def test_skip_while_pack_still_generating_does_not_count_the_unserved_question():
    """#182 awaiting path: the next question does not exist yet, so it must not
    be counted — the counter would otherwise jump ahead of the screen."""
    session = _session_on_third_question()
    session.pack_id = "pack_1"
    flow = _flow(next_question=None, pack_generating=True)

    result = await flow.process_answer(session=session, answer_text="skip")

    assert result.awaiting_question
    assert session_to_response(session).asked_count == 3
