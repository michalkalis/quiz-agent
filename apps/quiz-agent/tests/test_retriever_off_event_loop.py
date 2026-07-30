"""Adversarial audit 2026-07-30: question retrieval blocked the FastAPI event loop.

``QuestionRetriever`` is synchronous and its pgvector store bridges to a
background loop, blocking the calling thread until the query returns — and for
retrieval that includes a blocking OpenAI embedding HTTP call. Called straight
from an async handler it stalls *every* concurrent request for the duration
(measured ~0.4s per call in the audit repro). ``/voice/submit`` already offloaded
its prefetch with ``asyncio.to_thread``; the rest did not. This test pins that
the retriever runs off the loop thread, so re-inlining the call fails loudly
instead of silently reintroducing head-of-line blocking.
"""

import threading
from unittest.mock import AsyncMock, MagicMock

import pytest

from app.quiz.flow import QuizFlowService
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession
from quiz_shared.models.phase import SessionPhase


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


@pytest.mark.asyncio
async def test_retriever_calls_run_off_the_event_loop_thread():
    """Both blocking retriever calls in the answer path must execute on a worker
    thread, never on the thread running the event loop."""
    loop_thread = threading.get_ident()
    threads: dict[str, int] = {}

    def _get(question_id):
        threads["get"] = threading.get_ident()
        return _question(question_id)

    def _get_next(session, **_kwargs):
        threads["get_next_question"] = threading.get_ident()
        return _question("q_next")

    input_parser = MagicMock()
    input_parser.parse = AsyncMock(
        return_value=[{"intent_type": "answer", "extracted_data": {"answer": "Paris"}}]
    )
    question_retriever = MagicMock()
    question_retriever.get = _get
    question_retriever.get_next_question = _get_next

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

    session = QuizSession(
        session_id="s_1",
        phase=SessionPhase.ASKING,
        current_question_id="q_current",
        asked_question_ids=["q_current"],
        max_questions=10,
    )

    await flow.process_answer(session=session, answer_text="Paris")

    assert threading.get_ident() == loop_thread  # sanity: we are on the loop
    assert set(threads) == {"get", "get_next_question"}
    assert threads["get"] != loop_thread
    assert threads["get_next_question"] != loop_thread
