"""#188 G4 (founder 2026-10-06, audit finding D5): a skipped question spoke only
"Preskočené." — the static clip — so a driver who skipped never heard the right
answer without looking at the screen. A skip now gets the same synthesized
feedback as a miss: the skip word followed by the correct answer, in the session
language.
"""

import base64
from unittest.mock import AsyncMock, MagicMock

import pytest

from app.quiz.flow import QuizFlowService
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession


def _question() -> Question:
    return Question(
        id="q_current",
        question="What is the capital of France?",
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="general",
        difficulty="medium",
    )


def _session(language: str) -> QuizSession:
    return QuizSession(
        session_id="s_1",
        phase=SessionPhase.ASKING,
        language=language,
        current_question_id="q_current",
        asked_question_ids=["q_current"],
        max_questions=10,
    )


def _flow(tts) -> QuizFlowService:
    retriever = MagicMock()
    retriever.get = AsyncMock(return_value=_question())
    retriever.get_next_question = AsyncMock(return_value=None)
    return QuizFlowService(
        session_manager=MagicMock(),
        input_parser=MagicMock(),
        question_retriever=retriever,
        answer_evaluator=MagicMock(),
        tts_service=tts,
        usage_tracker=None,
        translation_service=None,
    )


@pytest.mark.asyncio
async def test_skip_feedback_audio_names_the_correct_answer():
    tts = MagicMock()
    tts.synthesize = AsyncMock(return_value=b"opus-bytes")
    flow = _flow(tts)

    result = await flow.process_answer(
        session=_session("en"), answer_text="skip", include_audio=True
    )

    assert result.evaluation.result == "skipped"
    spoken = tts.synthesize.await_args.kwargs["text"]
    assert spoken == "Skipped. The correct answer is Paris."
    # Delivered inline, not as the static "Skipped." clip URL.
    assert (
        result.audio_info.feedback_audio_base64
        == base64.b64encode(b"opus-bytes").decode()
    )
    assert result.audio_info.feedback_url is None


@pytest.mark.asyncio
async def test_skip_without_audio_requested_synthesizes_nothing():
    """Text-only clients must not pay for a TTS call they never play."""
    tts = MagicMock()
    tts.synthesize = AsyncMock(return_value=b"opus-bytes")
    flow = _flow(tts)

    await flow.process_answer(session=_session("en"), answer_text="skip")

    tts.synthesize.assert_not_awaited()
