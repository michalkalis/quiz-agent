"""The spoken feedback line must spell numbers out too (founder bug 2026-07-12).

Why this matters: "Nesprávne. Správna odpoveď je 1969." is what the driver
*hears* after every wrong answer. tts-1 has no locale lever, so a numeric
correct answer left as digits gets English pronunciation in the middle of a
Slovak sentence — the exact defect ``normalize_numbers_for_tts`` was written
to fix on /question/audio. It was never applied on this path, so the bug
stayed live on the half of the loop the user hears most.
"""

from unittest.mock import AsyncMock, MagicMock

import pytest
from app.quiz.flow import QuizFlowService
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession


class _RecordingTTS:
    """Captures the text actually handed to synthesis."""

    def __init__(self) -> None:
        self.texts: list[str] = []

    async def synthesize(self, text: str, use_cache: bool = True) -> bytes:
        self.texts.append(text)
        return b"audio"

    async def synthesize_question(self, question_text: str) -> bytes:
        return b"audio"


@pytest.mark.asyncio
async def test_slovak_numeric_answer_is_spelled_out_in_feedback_audio():
    """A wrong answer to a year question: the feedback TTS input has no digits."""
    question = Question(
        id="q_current",
        question="V ktorom roku pristáli ľudia na Mesiaci?",
        type="text",
        correct_answer="1969",
        topic="History",
        category="general",
        difficulty="medium",
    )
    session = QuizSession(
        session_id="s_1",
        phase=SessionPhase.ASKING,
        current_question_id="q_current",
        asked_question_ids=["q_current"],
        max_questions=10,
        language="sk",
    )

    input_parser = MagicMock()
    input_parser.parse = AsyncMock(
        return_value=[{"intent_type": "answer", "extracted_data": {"answer": "1972"}}]
    )
    question_retriever = MagicMock()
    question_retriever.get = MagicMock(return_value=question)
    question_retriever.get_next_question = MagicMock(return_value=None)
    answer_evaluator = MagicMock()
    answer_evaluator.evaluate = AsyncMock(return_value=("incorrect", 0.0))

    tts = _RecordingTTS()
    flow = QuizFlowService(
        session_manager=MagicMock(),
        input_parser=input_parser,
        question_retriever=question_retriever,
        answer_evaluator=answer_evaluator,
        tts_service=tts,
        usage_tracker=None,
        translation_service=None,
    )

    await flow.process_answer(session=session, answer_text="1972", include_audio=True)

    assert tts.texts, "feedback audio must be synthesized for an incorrect answer"
    spoken = tts.texts[0]
    assert "Správna odpoveď je" in spoken  # it IS the feedback line
    assert "1969" not in spoken
    assert "tisícdeväťstošesťdesiatdeväť" in spoken
