"""Adversarial audit 2026-07-30: the LLM judge's verdict parser scored a
rejected answer as full credit.

The fallback ladder matched `"correct" in result_text` before `"incorrect"`,
and "incorrect" *contains* "correct" — so every reply that was not the bare
lowercase word (`Incorrect.`, `**incorrect**`, `The answer is incorrect`) came
back as "correct" worth 1.0 points. Free-text answers are the only path that
reaches the judge, so the player was told they were right and scored a point.
These tests pin the punctuated/prose verdict shapes the ladder had zero
coverage for; a regression re-scoring any of them flips a wrong answer to right.
"""

import os

import pytest
from unittest.mock import AsyncMock, MagicMock

os.environ.setdefault("OPENAI_API_KEY", "sk-test")


def _make_question():
    from quiz_shared.models.question import Question

    return Question(
        id="q_verdict",
        question="How did the man in the field die?",
        type="text",
        correct_answer="His parachute failed to open",
        topic="Riddles",
        category="general",
        difficulty="medium",
    )


def _evaluator_replying(content: str):
    from app.evaluation.evaluator import AnswerEvaluator

    message = MagicMock()
    message.content = content
    choice = MagicMock()
    choice.message = message
    response = MagicMock()
    response.choices = [choice]

    async def _create(**_kwargs):
        return response

    evaluator = AnswerEvaluator()
    evaluator.client.chat.completions.create = _create
    return evaluator


class TestVerdictParsing:
    @pytest.mark.parametrize(
        "reply",
        [
            "incorrect",
            "Incorrect.",
            "**incorrect**",
            "The answer is incorrect",
            "INCORRECT",
            "incorrect\n",
        ],
    )
    @pytest.mark.asyncio
    async def test_rejection_never_scores_as_correct(self, reply):
        """A negative verdict in any punctuated/prose shape must stay negative
        and score 0.0 — the audited bug handed out 1.0 for all of these."""
        evaluator = _evaluator_replying(reply)

        result, score = await evaluator.evaluate("a heart attack", _make_question())

        assert result == "incorrect"
        assert score == 0.0

    @pytest.mark.parametrize(
        "reply",
        ["partially_incorrect", "Partially incorrect.", "**partially incorrect**"],
    )
    @pytest.mark.asyncio
    async def test_partially_incorrect_survives_the_space_variant(self, reply):
        """The space form of partially incorrect used to fall through to the
        "correct" branch — quarter credit must not become full credit."""
        evaluator = _evaluator_replying(reply)

        result, score = await evaluator.evaluate("he fell", _make_question())

        assert result == "partially_incorrect"
        assert score == 0.25

    @pytest.mark.parametrize(
        "reply", ["partially_correct", "Partially correct.", "**partially correct**"]
    )
    @pytest.mark.asyncio
    async def test_partially_correct_keeps_half_credit(self, reply):
        """Half credit must not be promoted to full credit by the looser match."""
        evaluator = _evaluator_replying(reply)

        result, score = await evaluator.evaluate("he fell", _make_question())

        assert result == "partially_correct"
        assert score == 0.5

    @pytest.mark.parametrize("reply", ["correct", "Correct!", "**correct**"])
    @pytest.mark.asyncio
    async def test_positive_verdict_still_scores_full_credit(self, reply):
        """The fix must not over-correct: a genuine "correct" still pays 1.0."""
        evaluator = _evaluator_replying(reply)

        result, score = await evaluator.evaluate(
            "his chute did not open", _make_question()
        )

        assert result == "correct"
        assert score == 1.0

    @pytest.mark.asyncio
    async def test_unparseable_reply_defaults_to_incorrect(self):
        """An unrecognisable judge reply must never award points."""
        evaluator = _evaluator_replying("I am not sure about this one")

        result, score = await evaluator.evaluate("something", _make_question())

        assert result == "incorrect"
        assert score == 0.0


class TestPartialCreditWeights:
    """The verdict → points table in ``AnswerEvaluator.evaluate`` (``score_map``).

    These are the only partial-credit weights in the product: half a point for
    "right idea, missing a qualifier" and a quarter for "related but mostly
    wrong". They are what a player's session score, and therefore the
    end-of-quiz result screen, is built from — silently changing 0.5 to 1.0
    would turn every near-miss into a win.

    Pinned one layer BELOW the tests above: those drive the reply-text → verdict
    parser, this stubs ``_llm_evaluate`` and drives verdict → score directly, so
    the weights stay pinned even if the parser is rewritten.
    """

    @pytest.mark.parametrize(
        "verdict,expected_points",
        [
            ("correct", 1.0),
            ("partially_correct", 0.5),
            ("partially_incorrect", 0.25),
            ("incorrect", 0.0),
        ],
    )
    @pytest.mark.asyncio
    async def test_verdict_maps_to_its_documented_weight(
        self, verdict, expected_points
    ):
        evaluator = _evaluator_replying("unused — the judge itself is stubbed")
        evaluator._llm_evaluate = AsyncMock(return_value=verdict)

        result, score = await evaluator.evaluate(
            "some free-text answer", _make_question()
        )

        assert result == verdict
        assert score == expected_points

    @pytest.mark.asyncio
    async def test_verdict_outside_the_table_pays_nothing(self):
        """``score_map.get(result, 0.0)`` — the default branch. A verdict the
        table does not know (a new label, a prompt change, a judge that answers
        in another language) must fall back to zero points rather than to the
        first/most generous entry. Guessing a score for an unrecognised verdict
        is how free credit leaks in."""
        evaluator = _evaluator_replying("unused")
        evaluator._llm_evaluate = AsyncMock(return_value="mostly_right")

        result, score = await evaluator.evaluate(
            "some free-text answer", _make_question()
        )

        assert result == "mostly_right"
        assert score == 0.0
