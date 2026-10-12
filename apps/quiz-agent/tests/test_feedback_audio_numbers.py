"""#200: the spoken correct answer gets the same number treatment as the question.

The question read-out spells digits in the session language before synthesis,
but the answer feedback ("Správna odpoveď je 1918.") went to TTS raw. On the
OpenAI fallback voice that reads "1918" in English inside a Slovak sentence —
the founder's "the Slovak voice reads years badly" (TF test 2026-10-12) — and an
ordinal date came out as "jeden. mája". English stays untouched.
"""

from unittest.mock import AsyncMock, MagicMock

import pytest

from app.quiz.flow import QuizFlowService
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

pytestmark = pytest.mark.asyncio


def _flow(tts, correct_answer: str) -> QuizFlowService:
    retriever = MagicMock()
    retriever.get = AsyncMock(
        return_value=Question(
            id="q_current",
            question="When did the war in Europe end?",
            type="text",
            correct_answer=correct_answer,
            topic="History",
            category="general",
            difficulty="medium",
        )
    )
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


async def _spoken_skip_feedback(language: str, correct_answer: str) -> str:
    tts = MagicMock()
    tts.synthesize = AsyncMock(return_value=b"audio")
    session = QuizSession(
        session_id="s_1",
        phase=SessionPhase.ASKING,
        language=language,
        current_question_id="q_current",
        asked_question_ids=["q_current"],
        max_questions=10,
    )
    await _flow(tts, correct_answer).process_answer(
        session=session, answer_text="skip", include_audio=True
    )
    return tts.synthesize.await_args.kwargs["text"]


@pytest.mark.parametrize(
    "language,answer,spoken",
    [
        ("sk", "1918", "Preskočené. Správna odpoveď je tisícdeväťstoosemnásť."),
        (
            "sk",
            "1. mája 1945",
            "Preskočené. Správna odpoveď je prvého mája tisícdeväťstoštyridsaťpäť.",
        ),
        ("cs", "1918", "Přeskočeno. Správná odpověď je tisíc devětset osmnáct."),
        ("en", "1918", "Skipped. The correct answer is 1918."),
    ],
)
async def test_feedback_audio_speaks_numbers_in_the_session_language(
    language, answer, spoken
):
    assert await _spoken_skip_feedback(language, answer) == spoken
