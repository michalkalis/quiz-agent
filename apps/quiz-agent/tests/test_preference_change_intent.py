"""Adversarial audit 2026-07-30: preference_change was read with a key the parser
never emits, so every spoken preference was silently dropped.

The parser emits ``avoid_topics`` / ``prefer_topics`` (lists) and ``difficulty``
("harder"/"easier"); the flow read ``extracted_data["topic"]``, defaulting to
"". Its own prompt example is "London. No more geography" → [answer,
preference_change], so the realistic path appended an EMPTY topic to
``preferred_topics`` and persisted it — after which the retriever's semantic
query degraded to "moderately challenging question about " for the rest of the
session. The sibling ``difficulty_change`` / ``category_change`` branches had no
producer at all and are gone. These tests pin each mapping the parser can
actually produce.
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


async def _run(extracted_data: dict, difficulty: str = "medium") -> QuizSession:
    """Drive the parser's own multi-intent example shape: [answer, preference_change].

    Returns the session after processing, which is also what the flow persists.
    """
    session = QuizSession(
        session_id="s_pref",
        phase=SessionPhase.ASKING,
        current_difficulty=difficulty,
        current_question_id="q_current",
        asked_question_ids=["q_current"],
        max_questions=10,
    )
    input_parser = MagicMock()
    input_parser.parse = AsyncMock(
        return_value=[
            {"intent_type": "answer", "extracted_data": {"answer": "Paris"}},
            {"intent_type": "preference_change", "extracted_data": extracted_data},
        ]
    )
    retriever = MagicMock()
    retriever.get = MagicMock(return_value=_question("q_current"))
    retriever.get_next_question = MagicMock(return_value=_question("q_next"))

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

    await flow.process_answer(session=session, answer_text="London. No more geography")
    flow.session_manager.update_session.assert_called_with(session)
    return session


async def test_avoid_topics_land_in_disliked_topics():
    """Saying "no more geography" must actually stop geography — the retriever
    reads disliked_topics, and nothing anywhere reads a "topic" key."""
    session = await _run({"avoid_topics": ["geography"]})

    assert session.disliked_topics == ["geography"]
    assert session.preferred_topics == []


async def test_prefer_topics_land_in_preferred_topics():
    """A positive preference must steer the semantic query, not be discarded."""
    session = await _run({"prefer_topics": ["space", "history"]})

    assert session.preferred_topics == ["space", "history"]
    assert session.disliked_topics == []


async def test_difficulty_harder_steps_one_level_up():
    """The parser emits a direction, the corpus stores levels — "harder" from
    medium is hard."""
    session = await _run({"difficulty": "harder"}, difficulty="medium")

    assert session.current_difficulty == "hard"


async def test_difficulty_easier_steps_one_level_down():
    session = await _run({"difficulty": "easier"}, difficulty="medium")

    assert session.current_difficulty == "easy"


async def test_difficulty_direction_clamps_at_the_ends():
    """Already hardest and asked for harder: stay hard. Never write "harder"
    into current_difficulty — that value matches no question in the corpus."""
    session = await _run({"difficulty": "harder"}, difficulty="hard")

    assert session.current_difficulty == "hard"


async def test_empty_and_missing_topics_are_never_appended():
    """The audited bug persisted preferred_topics=[""], which poisoned the
    semantic query for the rest of the session."""
    session = await _run({"avoid_topics": [""], "prefer_topics": []})

    assert session.preferred_topics == []
    assert session.disliked_topics == []


async def test_preference_change_with_no_data_is_a_no_op():
    """A preference intent the parser could not fill must change nothing."""
    session = await _run({})

    assert session.preferred_topics == []
    assert session.disliked_topics == []
    assert session.current_difficulty == "medium"
