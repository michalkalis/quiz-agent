"""A driver must HEAR the multiple-choice options, and only hear them.

Why this matters: the product is hands-free trivia while driving. The option
picker is on screen, which the driver cannot read, so before this an MCQ
question was simply unanswerable at the wheel — the driver heard "Roughly how
many Earth days does one Venus day last?" and had no idea 10 / 100 / 240 were
the choices.

The read-out is speech-only on purpose. ``session.current_question_text`` is
*also* the display text (GET /sessions/{id}/question) and the resume payload,
so appending options there would print the option list on screen next to the
picker that already shows it, and change what iOS decodes. These tests pin both
halves: the spoken string gains the options, the displayed string does not.

They also pin the gate. Only ``text_multichoice`` rows get a read-out:
true/false questions already name both choices in their own wording, and open
questions have no options at all — appending "Options." to either would be
noise the driver has to sit through on every question.
"""

from typing import ClassVar
from unittest.mock import MagicMock

import pytest
from app.api.routes.quiz import get_current_question
from app.api.routes.tts import get_question_audio
from app.session.manager import SessionManager
from quiz_shared.models.question import Question

pytestmark = pytest.mark.asyncio


class _Url:
    path = "/api/v1/sessions/x/question/audio"


class _Req:
    url = _Url()
    headers: ClassVar[dict] = {}


class _RecordingTTS:
    """Captures the text the route actually hands to synthesis."""

    def __init__(self) -> None:
        self.texts: list[str] = []

    async def synthesize_question(self, question_text: str) -> bytes:
        self.texts.append(question_text)
        return b"audio"


@pytest.fixture(autouse=True)
def _no_rate_limit(monkeypatch):
    from app import rate_limit

    monkeypatch.setattr(rate_limit.limiter, "enabled", False)


# Real corpus row (data/generated/claude_batch_012.json) — its options are bare
# numerals, the exact digits-read-in-English case fixed on 2026-07-12.
def _venus_mcq(question_text: str | None = None) -> Question:
    return Question(
        id="q_venus",
        question=(
            question_text or "Roughly how many Earth days does one Venus day last?"
        ),
        type="text_multichoice",
        possible_answers={"a": "10", "b": "100", "c": "240"},
        correct_answer="c",
        topic="Science",
        category="general",
        difficulty="medium",
    )


def _session_for(question: Question, language: str = "en"):
    manager = SessionManager()
    session = manager.create_session()
    session.language = language
    session.current_question_id = question.id
    session.current_question_text = question.question
    session.asked_question_ids = [question.id]
    manager.update_session(session)

    retriever = MagicMock()
    retriever.get.return_value = question
    return manager, session, retriever


async def _spoken_text(question: Question, language: str = "en") -> str:
    """Run the real /question/audio route, return what it sent to TTS."""
    manager, session, retriever = _session_for(question, language)
    tts = _RecordingTTS()

    await get_question_audio(
        request=_Req(),
        session_id=session.session_id,
        session_manager=manager,
        tts_service=tts,
        question_retriever=retriever,
        translation_service=None,
        _auth=None,
    )

    assert tts.texts, "the route must synthesize question audio"
    return tts.texts[0]


async def test_mcq_options_are_spoken_but_never_displayed():
    """The driver hears every choice; the on-screen text keeps only the question."""
    question = _venus_mcq()
    manager, session, retriever = _session_for(question)
    tts = _RecordingTTS()

    await get_question_audio(
        request=_Req(),
        session_id=session.session_id,
        session_manager=manager,
        tts_service=tts,
        question_retriever=retriever,
        translation_service=None,
        _auth=None,
    )

    spoken = tts.texts[0]
    assert spoken.startswith(question.question)
    assert "Options." in spoken
    # Letter labels, because repeating "A" is what the driver can actually do
    # at the wheel — and what the iOS MCQ matcher resolves exactly.
    assert "A: 10." in spoken
    assert "B: 100." in spoken
    assert "C: 240." in spoken

    displayed = await get_current_question(
        session_id=session.session_id,
        session_manager=manager,
        question_retriever=retriever,
        translation_service=None,
    )

    assert displayed["question"]["question"] == question.question
    assert "Options" not in displayed["question"]["question"]


async def test_true_false_question_speech_is_unchanged():
    """A true/false question already names both choices — nothing to append.

    These are stored as plain ``text`` rows with no ``possible_answers``, so a
    read-out here would be a pure regression: the driver would sit through
    "Options." with nothing after it before every true/false question.
    """
    question = Question(
        id="q_tf",
        question="True or false: Venus rotates in the opposite direction to Earth.",
        type="text",
        correct_answer="True",
        topic="Science",
        category="general",
        difficulty="easy",
    )

    assert await _spoken_text(question) == question.question


async def test_open_question_speech_is_unchanged():
    """An open question has no options; its spoken text must stay the question.

    This is the majority of the corpus, so a leaked label or stray separator
    here would change the cache key of nearly every question at once and
    invalidate the whole warm TTS cache.
    """
    question = Question(
        id="q_open",
        question="Which planet has the longest day in the solar system?",
        type="text",
        correct_answer="Venus",
        topic="Science",
        category="general",
        difficulty="medium",
    )

    assert await _spoken_text(question) == question.question


async def test_slovak_mcq_options_are_spelled_out():
    """Numeric options must be spelled out like the question already is.

    tts-1 has no locale lever: digits left inside Slovak text get English
    pronunciation (founder bug 2026-07-12). Option values are the worst case —
    "10 / 100 / 240" is a whole answer set the driver would hear in the wrong
    language, so the options have to join the string BEFORE normalization.
    """
    question = _venus_mcq("Približne koľko pozemských dní trvá jeden deň na Venuši?")

    spoken = await _spoken_text(question, language="sk")

    assert "Možnosti." in spoken
    # Slovak TTS reads a bare "A" as the conjunction *a* ("and"); the letter
    # names are also the vocabulary the iOS matcher accepts back.
    assert "Áčko: desať." in spoken
    assert "Béčko: sto." in spoken
    assert "Céčko: dvestoštyridsať." in spoken
    assert "10" not in spoken
    assert "240" not in spoken
