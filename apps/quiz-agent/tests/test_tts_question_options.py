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

They also pin the gate, which is narrower than "``text_multichoice``": open
questions have no options at all, and a true/false question — stored AS an
MCQ by the generation pipeline — already names both choices in its own
wording. Appending "Options." to either is noise the driver has to sit through
on every question.
"""

import pytest
from app.api.routes.quiz import get_current_question
from quiz_shared.models.question import GenerationProvenance, Question
from tests.question_audio_harness import (
    RecordingTTS,
    question_audio,
    start_quiz_for,
)

pytestmark = pytest.mark.asyncio


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


async def _spoken_text(question: Question, language: str = "en") -> str:
    """Run the real /start → /question/audio pair, return what reached TTS."""
    manager, session_id, retriever = await start_quiz_for(question, language)
    return await question_audio(manager, session_id, retriever, RecordingTTS())


async def test_mcq_options_are_spoken_but_never_displayed():
    """The driver hears every choice; the on-screen text keeps only the question."""
    question = _venus_mcq()
    manager, session_id, retriever = await start_quiz_for(question)

    spoken = await question_audio(manager, session_id, retriever, RecordingTTS())
    assert spoken.startswith(question.question)
    assert "Options." in spoken
    # Letter labels, because repeating "A" is what the driver can actually do
    # at the wheel — and what the iOS MCQ matcher resolves exactly.
    assert "A: 10." in spoken
    assert "B: 100." in spoken
    assert "C: 240." in spoken

    displayed = await get_current_question(
        session_id=session_id,
        session_manager=manager,
        question_retriever=retriever,
        translation_service=None,
    )

    assert displayed["question"]["question"] == question.question
    assert "Options" not in displayed["question"]["question"]


def _true_false(question_text: str) -> Question:
    """The shape the pipeline actually stores true/false questions in.

    ``true_false`` is in ``PATTERNS_TO_MCQ``
    (apps/quiz-pack-api/app/generation/pattern_routing.py) and the generator's
    recipe is ``type=text_multichoice`` with ``{"a": "True", "b": "False"}``
    (advanced_generator.py; craft_guards.true_false_key documents the same
    shape) — NOT a plain ``text`` row.
    """
    return Question(
        id="q_tf",
        question=question_text,
        type="text_multichoice",
        possible_answers={"a": "True", "b": "False"},
        correct_answer="a",
        topic="Science",
        category="general",
        difficulty="easy",
    )


async def test_true_false_question_speech_is_unchanged():
    """A true/false question already names both choices — nothing to append.

    Pinned in the corpus's real shape, because a type-only gate passes it: the
    Slovak driver then hears "Možnosti. Áčko: True. Béčko: False." after a
    question that already said "Pravda alebo nepravda", in English, since
    option values are never translated.
    """
    question = _true_false(
        "True or false: Venus rotates in the opposite direction to Earth."
    )

    assert await _spoken_text(question) == question.question

    slovak = _true_false("Pravda alebo nepravda: Venuša sa otáča opačne ako Zem.")
    spoken_sk = await _spoken_text(slovak, language="sk")

    assert spoken_sk == slovak.question
    assert "Možnosti" not in spoken_sk
    assert "True" not in spoken_sk


async def test_true_false_is_recognized_when_option_values_are_translated():
    """Provenance, not the English words, is what makes the gate future-proof.

    Question text is already translated per session; option values are not, but
    the moment they are, a values-only check ("true"/"false") stops matching and
    the read-out comes back. The generator stamps ``reasoning_pattern`` on every
    pattern-routed question, so it keeps identifying the shape.
    """
    question = _true_false("Pravda alebo nepravda: Venuša sa otáča opačne ako Zem.")
    question.possible_answers = {"a": "Pravda", "b": "Nepravda"}
    question.generation_metadata = GenerationProvenance(reasoning_pattern="true_false")

    assert await _spoken_text(question, language="sk") == question.question


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
