"""#204.6: the phonetic tier accepts respelled names, never a different answer.

A transcript like "Vašington" for "Washington" is the right answer spelled the
way it sounds; accepting it saves an LLM call. But a false accept gives a point
for a wrong answer, so the negatives matter as much as the positives: a
different vowel, a different number or a known wrong option must never pass.
"""

from __future__ import annotations

import os
from unittest.mock import AsyncMock

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

import pytest  # noqa: E402

from app.evaluation.evaluator import AnswerEvaluator  # noqa: E402
from app.evaluation.phonetic_match import phonetic_matches  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402


@pytest.mark.parametrize(
    "heard, expected",
    [
        ("Vašington", "Washington"),  # w→v, sh→š→s, final-ish voicing
        ("Vagner", "Wagner"),  # w→v
        ("Betóven", "Beethoven"),  # th→t, doubled e
        ("Filip", "Philip"),  # ph→f
        ("Ksaver", "Xaver"),  # x→ks
        ("Hemia", "Chemia"),  # ch→h (sk/cs)
        ("Kuba", "Cuba"),  # hard c→k
        ("Mýtus", "Mitus"),  # y→i
        ("Lev Tolstoj", "Lev Tolstoy"),  # y→i in a multi-word answer
    ],
)
def test_respelled_answers_share_a_key(heard, expected):
    assert phonetic_matches(heard, [expected])


@pytest.mark.parametrize(
    "heard, expected",
    [
        ("pas", "pes"),  # different vowel is a different word
        ("Karel", "Karol"),
        ("Paris", "Parma"),
        ("Henry VII", "Henry VIII"),  # roman numerals never bend
        ("rok 1914", "rok 1915"),
        ("tri", "tru"),
        ("Vitamin Q", "Vitamin K"),  # single letters carry no sound
        ("Lev Tolstoj", "Tolstoj"),  # different word count
        ("", "Paris"),
    ],
)
def test_different_answers_never_share_a_key(heard, expected):
    assert not phonetic_matches(heard, [expected])


def test_numerals_are_refused_even_when_identical_keys_would_match():
    assert not phonetic_matches("Henry 8", ["Henri 8"])


def test_a_known_wrong_option_that_sounds_alike_blocks_the_accept():
    """If "Vagner" is itself a listed wrong answer, hearing it is not evidence
    of the correct "Wagner"."""
    assert phonetic_matches("Vagner", ["Wagner"])
    assert not phonetic_matches("Vagner", ["Wagner"], distractors=["Vagner"])


def _question() -> Question:
    return Question(
        id="q",
        question="Ktoré mesto je hlavné v USA?",
        type="text",
        correct_answer="Washington",
        topic="Geography",
        category="geography",
        difficulty="easy",
    )


@pytest.mark.asyncio
async def test_flag_off_by_default_sends_the_respelling_to_the_judge(monkeypatch):
    monkeypatch.delenv("ANSWER_PHONETIC_MATCH", raising=False)
    ev = AnswerEvaluator()
    ev._llm_evaluate = AsyncMock(return_value="incorrect")

    result, _ = await ev.evaluate("Vašington", _question())

    assert result == "incorrect"
    ev._llm_evaluate.assert_awaited_once()


@pytest.mark.asyncio
async def test_flag_on_accepts_without_calling_the_judge(monkeypatch):
    monkeypatch.setenv("ANSWER_PHONETIC_MATCH", "true")
    ev = AnswerEvaluator()
    ev._llm_evaluate = AsyncMock(return_value="incorrect")

    result, points = await ev.evaluate("Vašington", _question())

    assert (result, points) == ("correct", 1.0)
    ev._llm_evaluate.assert_not_awaited()
