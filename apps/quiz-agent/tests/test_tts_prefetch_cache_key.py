"""Adversarial audit 2026-07-30: the TTS prefetch warmed a cache key the audio
route never reads.

``GET /sessions/{id}/question/audio`` synthesizes
``normalize_numbers_for_tts(text, language)`` (founder bug 2026-07-12: tts-1
reads embedded digits with English pronunciation in Slovak text), but the
prefetch synthesized the raw stem. The cache key is the exact text, so for any
Slovak/Czech stem containing a digit — 12 of 69 in the corpus — prefetch and
serve hashed different strings: two metered ElevenLabs syntheses, and the
prefetch that exists to make iOS hit a warm cache never did.

These tests pin one synthesis per question text, on both prefetch call sites
(``/start`` and the answer-advance path).
"""

import asyncio
from unittest.mock import AsyncMock, MagicMock

import pytest

from app.api.deps import StartQuizRequest
from app.api.routes.quiz import start_quiz
from app.api.routes.tts import get_question_audio
from app.quiz import flow as flow_module
from app.quiz.flow import QuizFlowService, prefetch_question_audio
from app.session.manager import SessionManager
from app.tts.service import TTSService
from quiz_shared.models.question import Question
from quiz_shared.models.phase import SessionPhase

pytestmark = pytest.mark.asyncio

SK_STEM = "V ktorom roku 1969 pristáli ľudia na Mesiaci?"


class _Url:
    path = "/api/v1/sessions/x/question/audio"


class _Req:
    url = _Url()
    headers: dict = {}


class CountingProvider:
    """Counts real synthesis calls — a cache miss is the thing under test."""

    name = "counting"
    default_voice = "test-voice"

    def __init__(self) -> None:
        self.calls: list[str] = []

    async def synthesize(self, text: str, voice: str) -> bytes:
        self.calls.append(text)
        return b"audio-bytes"


@pytest.fixture(autouse=True)
def _isolated_tts(tmp_path, monkeypatch):
    monkeypatch.setenv("TTS_CACHE_DIR", str(tmp_path / "tts_cache"))
    monkeypatch.setenv("TTS_FALLBACK_PROVIDER", "none")
    from app import rate_limit

    monkeypatch.setattr(rate_limit.limiter, "enabled", False)


def _service() -> tuple[TTSService, CountingProvider]:
    provider = CountingProvider()
    return TTSService(provider=provider), provider


async def _drain_prefetch() -> None:
    await asyncio.gather(*list(flow_module._prefetch_tasks))


def _question(qid: str = "q_next", text: str = SK_STEM) -> Question:
    return Question(
        id=qid,
        question=text,
        type="text",
        correct_answer="1969",
        topic="Space",
        category="general",
        difficulty="medium",
        review_status="approved",
    )


async def test_prefetch_then_serve_synthesizes_once_for_a_slovak_digit_stem():
    """Prefetch must warm the key the audio route reads: exactly one metered
    synthesis for one question, and it must be the digits-spelled-out text."""
    service, provider = _service()
    manager = SessionManager()
    session = manager.create_session()
    session.language = "sk"
    session.transition(to=SessionPhase.ASKING, caller="test")
    session.current_question_id = "q_next"
    session.current_question_text = SK_STEM
    manager.update_session(session)

    prefetch_question_audio(service, SK_STEM, "sk")
    await _drain_prefetch()

    # No translation record on the session → the route re-reads the question
    # for possible MCQ options (2026-08-03); a text question adds none.
    retriever = MagicMock()
    retriever.get = MagicMock(return_value=_question("q_next", SK_STEM))

    await get_question_audio(
        request=_Req(),
        session_id=session.session_id,
        session_manager=manager,
        tts_service=service,
        question_retriever=retriever,
        translation_service=None,
    )

    assert len(provider.calls) == 1
    assert "1969" not in provider.calls[0]
    assert "tisícdeväťsto" in provider.calls[0]


async def test_answer_advance_prefetch_uses_the_session_language():
    """The answer-advance prefetch must normalize with the *session's* language —
    passing the raw stem (or "en") re-opens the double-synthesis."""
    service, provider = _service()
    session = SessionManager().create_session()
    session.language = "sk"
    session.transition(to=SessionPhase.ASKING, caller="test")
    session.current_question_id = "q_current"
    session.asked_question_ids = ["q_current"]

    input_parser = MagicMock()
    input_parser.parse = AsyncMock(
        return_value=[{"intent_type": "answer", "extracted_data": {"answer": "1969"}}]
    )
    retriever = MagicMock()
    retriever.get = MagicMock(return_value=_question("q_current", "Kedy?"))
    retriever.get_next_question = MagicMock(return_value=_question())

    flow = QuizFlowService(
        session_manager=MagicMock(),
        input_parser=input_parser,
        question_retriever=retriever,
        answer_evaluator=MagicMock(),
        tts_service=service,
        usage_tracker=None,
        translation_service=None,
    )
    flow.answer_evaluator.evaluate = AsyncMock(return_value=("correct", 1.0))

    await flow.process_answer(session=session, answer_text="1969", include_audio=True)
    await _drain_prefetch()

    assert SK_STEM not in provider.calls  # the un-normalized stem is a dead key
    assert any("tisícdeväťsto" in c for c in provider.calls)


async def test_start_prefetch_uses_the_session_language():
    """Same for the /start prefetch — the other call site of the same helper."""
    service, provider = _service()
    manager = SessionManager()
    session = manager.create_session()
    session.language = "sk"
    manager.update_session(session)

    retriever = MagicMock()
    retriever.get_next_question = MagicMock(return_value=_question())

    await start_quiz(
        request=_Req(),
        session_id=session.session_id,
        body=StartQuizRequest(),
        session_manager=manager,
        question_retriever=retriever,
        usage_tracker=None,
        translation_service=None,
        tts_service=service,
        audio=True,
    )
    await _drain_prefetch()

    assert SK_STEM not in provider.calls
    assert any("tisícdeväťsto" in c for c in provider.calls)
