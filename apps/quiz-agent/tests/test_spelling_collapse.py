"""Spelled-out answers are joined into one word before grading (#208.2).

TF test 2026-10-16: the recogniser kept mishearing "Váh", so the founder
spelled it and the transcript came back as "V A H". Separate letters match
nothing — not the exact match, not the sound-alike tiers, not the judge — so a
player who does the sensible thing (spell it) was still marked wrong. The join
must never change the meaning of ordinary speech, which is full of one-letter
words ("a", "v") and letter-name look-alikes ("je", Czech "té").
"""

from __future__ import annotations

import unicodedata
from unittest.mock import AsyncMock

import pytest

from app.evaluation.spelling import collapse_spelling
from app.quiz.flow import parse_answer_intents
from quiz_shared.models.question import Question


def _folded(text: str) -> str:
    """Case- and diacritic-folded, punctuation dropped: how the word is matched."""
    decomposed = unicodedata.normalize("NFKD", text.lower())
    return "".join(c for c in decomposed if c.isalnum() and c.isascii())


@pytest.mark.parametrize(
    "heard,spelled",
    [
        # sk: the replay recording 20261016-132942 and the plan's examples
        ("V A H", "vah"),
        ("P. A. R. Í. Ž.", "pariz"),
        ("P-A-R-Í-Ž", "pariz"),
        ("pé á er í žet", "pariz"),
        ("Bé é ká", "bek"),
        # cs: same names, Czech spelling of the word
        ("Pé, er, á, há, á.", "praha"),
        # en
        ("bee E ar el I N", "berlin"),
        ("dee O vee E R", "dover"),
        ("double u A L E S", "wales"),
    ],
)
def test_spelling_becomes_the_word(heard, spelled):
    assert _folded(collapse_spelling(heard)) == spelled


@pytest.mark.parametrize(
    "heard,word",
    [
        ("V A H váh.", "váh."),  # spelled, then said: the word is kept
        ("Váh, V A H", "Váh,"),  # said, then spelled
        ("P-A-R-Í-Ž Paríž", "Paríž"),
    ],
)
def test_the_spoken_word_next_to_its_spelling_wins(heard, word):
    assert collapse_spelling(heard) == word


def test_the_rest_of_the_sentence_is_kept():
    assert collapse_spelling("Je to V A H, rieka") == "Je to VAH, rieka"


@pytest.mark.parametrize(
    "heard",
    [
        # Short real answers and words that look like letters
        "a",
        "v",
        "Auto",
        "USA",
        "e-mail",
        "J. K. Rowling",  # two initials are not a spelling
        # sk/cs one-letter words and letter-name look-alikes in a row
        "a je v Paríži",
        "A v té době",
        "je to v Ázii",
        "a i v",
        "e e e Praha",  # hesitation
        # en: names that are everyday words are not letters
        "you are a star",
        "I see a bee",
        "I am a doctor",
        "Reset hesla.",
    ],
)
def test_ordinary_speech_is_never_changed(heard):
    assert collapse_spelling(heard) == heard


def _question(**overrides) -> Question:
    base = dict(
        id="q",
        question="Ktorá rieka tečie cez Trenčín?",
        type="text",
        correct_answer="Váh",
        topic="Geografia",
        category="geography",
        difficulty="medium",
    )
    base.update(overrides)
    return Question(**base)


def _parser():
    parser = AsyncMock()
    parser.parse.return_value = [{"intent_type": "answer", "extracted_data": {}}]
    return parser


@pytest.mark.asyncio
async def test_the_parser_and_judge_see_the_joined_word():
    """Joined before the intent parser, so it extracts the word, not letters."""
    parser = _parser()

    await parse_answer_intents("V A H", _question(), "awaiting_answer", parser)

    assert parser.parse.await_args.kwargs["user_input"] == "VAH"


@pytest.mark.asyncio
async def test_mcq_letters_are_left_alone():
    """In an MCQ, single letters are option labels ("A B C" is not a word)."""
    parser = _parser()
    question = _question(
        type="text_multichoice",
        possible_answers={"a": "Váh", "b": "Hron", "c": "Nitra", "d": "Morava"},
        correct_answer="a",
    )

    await parse_answer_intents("A B C", question, "awaiting_answer", parser)

    assert parser.parse.await_args.kwargs["user_input"] == "A B C"
