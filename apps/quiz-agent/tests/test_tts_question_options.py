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
    StubTranslator,
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


def _landmark_mcq() -> Question:
    """An MCQ whose options are words, not numerals — the untranslatable case.

    One option has an established Slovak form and one (a proper name) does not,
    which is the mix the real corpus produces.
    """
    return Question(
        id="q_landmark",
        question="Which landmark stands in Paris?",
        type="text_multichoice",
        possible_answers={"a": "the Eiffel Tower", "b": "Big Ben"},
        correct_answer="a",
        topic="Geography",
        category="general",
        difficulty="easy",
    )


def _landmark_translator() -> StubTranslator:
    return StubTranslator(
        {
            "Which landmark stands in Paris?": "Ktorá pamiatka stojí v Paríži?",
            "the Eiffel Tower": "Eiffelova veža",
            # "Big Ben" deliberately absent: the real service returns the
            # original when it has no translation, and that must survive.
        }
    )


async def test_slovak_session_never_speaks_english_option_values():
    """The read-out made the untranslated corpus audible, and unusable.

    Before this, a Slovak session spoke a Slovak sentence with English option
    values — read by a Slovak voice, so "the Eiffel Tower" came out as Slovak
    phonetics of English words. The driver cannot answer what they cannot
    parse, which is the whole reason the options are spoken at all.
    """
    translator = _landmark_translator()
    manager, session_id, retriever = await start_quiz_for(
        _landmark_mcq(), "sk", translation_service=translator
    )

    spoken = await question_audio(
        manager, session_id, retriever, RecordingTTS(), translator
    )

    assert "Áčko: Eiffelova veža." in spoken
    assert "Eiffel Tower" not in spoken
    assert "Béčko: Big Ben." in spoken  # no Slovak form → original, not mangled


async def test_display_and_speech_carry_the_same_option_values():
    """One projection feeds both, so the screen can never list other choices.

    ``question_to_dict_translated`` is where the options are translated
    precisely so the client's picker and the TTS read-out cannot disagree — a
    driver told "Áčko: Eiffelova veža" while the screen offers "the Eiffel
    Tower" has two answer sets for one question.
    """
    translator = _landmark_translator()
    manager, session_id, retriever = await start_quiz_for(
        _landmark_mcq(), "sk", translation_service=translator
    )

    spoken = await question_audio(
        manager, session_id, retriever, RecordingTTS(), translator
    )
    displayed = await get_current_question(
        session_id=session_id,
        session_manager=manager,
        question_retriever=retriever,
        translation_service=translator,
    )

    options = displayed["question"]["possible_answers"]
    assert options == {"a": "Eiffelova veža", "b": "Big Ben"}
    # Keys are untouched: they are what the driver's spoken letter resolves to.
    for key, value in options.items():
        assert f"{'Áčko' if key == 'a' else 'Béčko'}: {value}." in spoken


async def test_legacy_session_rebuild_also_speaks_translated_options():
    """The rebuild path must not be the one place English options come back.

    A session written before the speech text was cached rebuilds it from the
    question row — which is English-only. Rebuilding from the row's own values
    would put English options back in a Slovak driver's ear on exactly the
    sessions a mid-quiz deploy touches.
    """
    translator = _landmark_translator()
    manager, session_id, retriever = await start_quiz_for(
        _landmark_mcq(), "sk", translation_service=translator
    )

    session = manager.get_session(session_id)
    session.current_question_speech_text = None
    manager.update_session(session)

    spoken = await question_audio(
        manager, session_id, retriever, RecordingTTS(), translator
    )

    assert "Áčko: Eiffelova veža." in spoken
    assert "Eiffel Tower" not in spoken


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
