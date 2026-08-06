"""In-quiz voice preference changes were removed (founder, 2026-07-31).

"Switch to easier questions" is no longer an intent the parser emits and no
longer mutates the session. What must survive is the answer: an utterance that
mixes an answer with a preference phrase is still graded on the answer alone,
and nothing writes topic/difficulty preferences behind the player's back.
"""

from unittest.mock import AsyncMock, MagicMock

import pytest

from app.quiz.flow import QuizFlowService
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession
from quiz_shared.models.phase import SessionPhase

pytestmark = pytest.mark.asyncio


def _question(qid: str) -> Question:
    return Question(
        id=qid,
        question="What is the capital of France?",
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="general",
        difficulty="medium",
    )


def _flow(intents):
    input_parser = MagicMock()
    input_parser.parse = AsyncMock(return_value=intents)

    retriever = MagicMock()
    retriever.get = AsyncMock(return_value=_question("q_current"))
    retriever.get_next_question = AsyncMock(return_value=_question("q_next"))

    flow = QuizFlowService(
        session_manager=MagicMock(),
        input_parser=input_parser,
        question_retriever=retriever,
        answer_evaluator=MagicMock(),
        tts_service=None,
        usage_tracker=None,
        translation_service=None,
    )
    flow.answer_evaluator.evaluate = AsyncMock(return_value=("correct", 1.0))
    return flow


def _session() -> QuizSession:
    return QuizSession(
        session_id="s_pref",
        phase=SessionPhase.ASKING,
        current_difficulty="medium",
        current_question_id="q_current",
        asked_question_ids=["q_current"],
        max_questions=10,
    )


async def test_answer_carrying_a_preference_phrase_is_still_graded():
    """The player said an answer; the trailing "no more geography" must not cost
    them the grade."""
    session = _session()
    flow = _flow([{"intent_type": "answer", "extracted_data": {"answer": "Paris"}}])

    result = await flow.process_answer(
        session=session, answer_text="Paris. No more geography"
    )

    assert result.evaluation.result == "correct"
    assert session.preferred_topics == []
    assert session.disliked_topics == []
    assert session.current_difficulty == "medium"
