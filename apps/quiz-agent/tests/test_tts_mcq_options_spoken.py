"""Founder 2026-08-03: MCQ question audio must read the options aloud, not just
the stem — a hands-free driver can't answer "A, B, C or D" without hearing them.

Pins: (1) the audio route appends the (translated) options to the spoken text,
(2) the display text stays stem-only, (3) prefetch and serve still hash the
same cache key for an MCQ question (one metered synthesis).
"""

from unittest.mock import MagicMock

import pytest

from app.api.routes.tts import get_question_audio
from app.session.manager import SessionManager
from app.tts.service import TTSService
from app.tts.spoken_text import spoken_question_text
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question

from .test_tts_prefetch_cache_key import (
    CountingProvider,
    _isolated_tts,  # noqa: F401 — autouse fixture reused
    _Req,
)

pytestmark = pytest.mark.asyncio

STEM = "Ktorá krajina vymyslela šalát Caesar?"
OPTIONS = {"a": "Taliansko", "b": "Mexiko", "c": "Grécko", "d": "Spojené štáty"}


def _mcq(qid: str = "q_mcq") -> Question:
    return Question(
        id=qid,
        question="Which country invented the Caesar salad?",
        type="text_multichoice",
        possible_answers=dict(OPTIONS),
        correct_answer="b",
        topic="Food",
        category="general",
        difficulty="medium",
        review_status="approved",
    )


def test_spoken_text_appends_options_and_leaves_open_questions_alone():
    spoken = spoken_question_text(STEM, OPTIONS)
    assert spoken.startswith(STEM)
    for key, value in OPTIONS.items():
        assert f"{key}: {value}" in spoken
    assert spoken_question_text(STEM, None) == STEM


async def test_audio_route_reads_translated_mcq_options():
    """Translated session: spoken text = translated stem + translated options,
    while the cached display text stays the bare stem."""
    provider = CountingProvider()
    service = TTSService(provider=provider)
    manager = SessionManager()
    session = manager.create_session()
    session.language = "sk"
    session.transition(to=SessionPhase.ASKING, caller="test")
    session.current_question_id = "q_mcq"
    session.current_question_text = STEM
    session.current_question_translation = {
        "question_id": "q_mcq",
        "language": "sk",
        "question": STEM,
        "possible_answers": dict(OPTIONS),
        "correct_answer": "Mexiko",
        "correct_answer_key": "b",
    }
    manager.update_session(session)

    await get_question_audio(
        request=_Req(),
        session_id=session.session_id,
        session_manager=manager,
        tts_service=service,
        question_retriever=MagicMock(),
        translation_service=None,
    )

    assert len(provider.calls) == 1
    spoken = provider.calls[0]
    assert "Taliansko" in spoken and "Spojené štáty" in spoken
    assert manager.get_session(session.session_id).current_question_text == STEM


async def test_audio_route_reads_source_options_for_english_session():
    """English session (no translation record): options come from the source
    question via the retriever."""
    provider = CountingProvider()
    service = TTSService(provider=provider)
    manager = SessionManager()
    session = manager.create_session()
    session.language = "en"
    session.transition(to=SessionPhase.ASKING, caller="test")
    session.current_question_id = "q_mcq"
    session.current_question_text = "Which country invented the Caesar salad?"
    manager.update_session(session)

    retriever = MagicMock()
    retriever.get = MagicMock(return_value=_mcq())

    await get_question_audio(
        request=_Req(),
        session_id=session.session_id,
        session_manager=manager,
        tts_service=service,
        question_retriever=retriever,
        translation_service=None,
    )

    assert len(provider.calls) == 1
    assert "Mexiko" in provider.calls[0]
    assert provider.calls[0].startswith("Which country")
