"""The TTS warm-up must warm the exact cache key /question/audio reads.

Why this matters: /question/audio synthesizes the digit-*normalized* text
(founder bug 2026-07-12 — tts-1 reads embedded digits with English
pronunciation inside Slovak), and the cache key is a hash of that final text.
If the prefetch warms the raw text instead, then for every Slovak/Czech
question containing a number the warm-up writes a key nobody ever reads: the
prefetch is a silent double-spend on OpenAI TTS *and* the driver still pays the
full synthesis latency on the hands-free hot path — the exact cost the prefetch
exists to avoid.
"""

import asyncio
from typing import ClassVar
from unittest.mock import MagicMock

import pytest
from app.api.routes.tts import get_question_audio
from app.quiz.flow import prefetch_question_audio
from app.session.manager import SessionManager
from app.tts.cache import TTSCache
from app.tts.number_normalization import normalize_numbers_for_tts
from app.tts.voices import DEFAULT_VOICE
from quiz_shared.models.question import Question


class _RecordingTTS:
    """Captures the text the prefetch actually sends to synthesis."""

    def __init__(self) -> None:
        self.texts: list[str] = []
        self.called = asyncio.Event()

    async def synthesize_question(self, question_text: str) -> bytes:
        self.texts.append(question_text)
        self.called.set()
        return b"audio"


@pytest.mark.asyncio
async def test_prefetch_warms_the_key_the_route_reads(tmp_path):
    """Slovak question with a year: prefetch key == /question/audio key."""
    question = "V roku 1969 pristáli ľudia na Mesiaci."
    route_text = normalize_numbers_for_tts(question, "sk")

    tts = _RecordingTTS()
    prefetch_question_audio(tts, question, "sk", None)
    await asyncio.wait_for(tts.called.wait(), timeout=1)

    cache = TTSCache(cache_dir=str(tmp_path / "tts_cache"))
    route_key = cache._hash(route_text, DEFAULT_VOICE)
    raw_key = cache._hash(question, DEFAULT_VOICE)

    # Guard: the fixture must actually be rewritten by normalization, otherwise
    # the assertion below would pass for the wrong reason.
    assert route_key != raw_key

    assert cache._hash(tts.texts[0], DEFAULT_VOICE) == route_key


@pytest.mark.asyncio
async def test_prefetch_warms_the_mcq_key_the_route_reads(tmp_path, monkeypatch):
    """MCQ: the warm-up must include the spoken options the route appends.

    Same invariant, second way to break it: the route now speaks the option
    list, so a prefetch that warms only the question text is a key nobody
    reads. Drives BOTH real call sites and compares the strings they actually
    synthesized, rather than re-deriving either one in the test.
    """
    from app import rate_limit

    monkeypatch.setattr(rate_limit.limiter, "enabled", False)

    question = Question(
        id="q_mcq",
        question="Približne koľko pozemských dní trvá jeden deň na Venuši?",
        type="text_multichoice",
        possible_answers={"a": "10", "b": "100", "c": "240"},
        correct_answer="c",
        topic="Science",
        category="general",
        difficulty="medium",
    )

    prefetch_tts = _RecordingTTS()
    prefetch_question_audio(prefetch_tts, question.question, "sk", question)
    await asyncio.wait_for(prefetch_tts.called.wait(), timeout=1)

    manager = SessionManager()
    session = manager.create_session()
    session.language = "sk"
    session.current_question_id = question.id
    session.current_question_text = question.question
    manager.update_session(session)

    retriever = MagicMock()
    retriever.get.return_value = question

    class _Url:
        path = "/api/v1/sessions/x/question/audio"

    class _Req:
        url = _Url()
        headers: ClassVar[dict] = {}

    route_tts = _RecordingTTS()
    await get_question_audio(
        request=_Req(),
        session_id=session.session_id,
        session_manager=manager,
        tts_service=route_tts,
        question_retriever=retriever,
        translation_service=None,
        _auth=None,
    )

    cache = TTSCache(cache_dir=str(tmp_path / "tts_cache"))
    route_key = cache._hash(route_tts.texts[0], DEFAULT_VOICE)

    # Guard: the route text must genuinely carry the options, otherwise the
    # parity assertion below would pass on two identical bare questions.
    assert route_key != cache._hash(question.question, DEFAULT_VOICE)
    assert "Možnosti" in route_tts.texts[0]

    assert cache._hash(prefetch_tts.texts[0], DEFAULT_VOICE) == route_key
