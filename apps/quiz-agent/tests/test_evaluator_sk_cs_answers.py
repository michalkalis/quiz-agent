"""Slovak/Czech open answers through the evaluator's deterministic layers.

Why: the app is tested in Slovak/Czech and the STT transcript (Scribe) drops or
adds diacritics unpredictably. The deterministic pre-check (``fold`` +
``sounds_like``) must forgive that without an LLM call — cheap, fast, stable —
while a different grammatical case or a different word order is NOT something
string matching may judge: it has to reach the (stubbed) LLM verdict, and that
verdict must stand. A regression either way costs a wrong score or a wasted
LLM call on the hot path.
"""

from __future__ import annotations

import os

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

from unittest.mock import AsyncMock

import pytest
from app.evaluation.evaluator import AnswerEvaluator
from quiz_shared.models.question import Question

# (transcript without/with other diacritics, canonical answer): accepted with no LLM.
DIACRITICS_DIFFER = [
    ("Zilina", "Žilina"),  # sk
    ("Stefanik", "Štefánik"),  # sk
    ("cesky", "český"),  # cs
    ("Mikulas Kopernik", "Mikuláš Koperník"),  # sk/cs, multi-word
    ("Karlov most", "Karlův most"),  # cs: ů vs o
]

# Same entity, but string matching must not claim to understand it: a different
# case ending or another word order is the judge's call.
INFLECTION_OR_ORDER = [
    ("Bratislavy", "Bratislava"),  # genitive of the capital
    ("Prahu", "Praha"),  # accusative
    ("Jan Hus", "Hus Jan"),  # word order
    ("Hrad Devín", "Devín hrad"),  # word order
]


def _question(correct: str, language: str) -> Question:
    return Question(
        id="q_skcs",
        question="Otázka?",
        type="text",
        correct_answer=correct,
        topic="Geografia",
        category="geography",
        difficulty="medium",
        language=language,
    )


@pytest.mark.parametrize("heard,expected", DIACRITICS_DIFFER)
@pytest.mark.asyncio
async def test_missing_diacritics_are_correct_without_the_judge(heard, expected):
    """A transcript that lost the diacritics earns full credit with no LLM call
    (the judge is stubbed to blow up if the fast path ever stops covering this)."""
    evaluator = AnswerEvaluator()
    evaluator._llm_evaluate = AsyncMock(
        side_effect=AssertionError(
            "diacritics-only difference must not reach the judge"
        )
    )

    assert await evaluator.evaluate(heard, _question(expected, "sk")) == (
        "correct",
        1.0,
    )


@pytest.mark.parametrize("heard,expected", INFLECTION_OR_ORDER)
@pytest.mark.parametrize(("verdict", "points"), [("correct", 1.0), ("incorrect", 0.0)])
@pytest.mark.asyncio
async def test_other_case_or_word_order_is_decided_by_the_judge(
    heard, expected, verdict, points
):
    """Not deterministically accepted, and not deterministically rejected: the
    judge is asked exactly once and its verdict is what scores, both ways."""
    evaluator = AnswerEvaluator()
    evaluator._llm_evaluate = AsyncMock(return_value=verdict)

    result = await evaluator.evaluate(heard, _question(expected, "cs"))

    assert result == (verdict, points)
    evaluator._llm_evaluate.assert_awaited_once()
    assert evaluator._llm_evaluate.await_args.kwargs["user_answer"] == heard
    assert evaluator._llm_evaluate.await_args.kwargs["correct_answer"] == expected
