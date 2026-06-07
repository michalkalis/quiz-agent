"""Tests for 46.B7: open-shape questions score against `headline_answer`.

Open-shape questions (mechanism/cause/puzzle) carry a long `correct_answer`
resolution plus a short `headline_answer` gist — the gettable answer a player
speaks while driving. The evaluator must score the spoken answer against that
gist, not the long resolution (which would never match a short answer).
"""

import os

import pytest
from unittest.mock import AsyncMock

os.environ.setdefault("OPENAI_API_KEY", "sk-test")


def _make_open_question(*, correct_answer: str, headline_answer):
    from quiz_shared.models.question import Question

    return Question(
        id="q_open",
        question="Why are Ferraris red?",
        type="text",
        correct_answer=correct_answer,
        headline_answer=headline_answer,
        topic="Motorsport",
        category="adults",
        difficulty="medium",
    )


class TestHeadlineAnswerEvaluation:
    @pytest.mark.asyncio
    async def test_fast_path_matches_headline_not_long_resolution(self):
        """A spoken answer equal to the short gist is correct via the fast path,
        even though the long `correct_answer` would never match it."""
        from app.evaluation.evaluator import AnswerEvaluator

        evaluator = AnswerEvaluator()
        # The LLM path must not fire — the fast path should match the gist.
        evaluator._llm_evaluate = AsyncMock(
            side_effect=AssertionError("fast path should match headline_answer")
        )

        q = _make_open_question(
            correct_answer=(
                "Italy's national motor-racing colour was red, so Ferraris "
                "inherited it from the early Grand Prix era."
            ),
            headline_answer="National racing colour",
        )

        result, score = await evaluator.evaluate("national racing colour", q, q.question)

        assert result == "correct"
        assert score == 1.0

    @pytest.mark.asyncio
    async def test_llm_scored_against_headline_when_present(self):
        """When no exact match, the LLM is handed the short gist as the answer to
        compare against — not the long resolution."""
        from app.evaluation.evaluator import AnswerEvaluator

        evaluator = AnswerEvaluator()
        evaluator._llm_evaluate = AsyncMock(return_value="correct")

        long_resolution = (
            "Italy's national motor-racing colour was red, so Ferraris "
            "inherited it from the early Grand Prix era."
        )
        q = _make_open_question(
            correct_answer=long_resolution,
            headline_answer="National racing colour",
        )

        result, score = await evaluator.evaluate("the racing colours", q, q.question)

        assert result == "correct"
        assert score == 1.0
        # The gist, not the long resolution, is what the LLM judged against.
        assert evaluator._llm_evaluate.await_args.kwargs["correct_answer"] == (
            "National racing colour"
        )

    @pytest.mark.asyncio
    async def test_falls_back_to_correct_answer_without_headline(self):
        """Closed questions (no headline_answer) keep scoring against
        `correct_answer` — the existing path is unchanged."""
        from app.evaluation.evaluator import AnswerEvaluator

        evaluator = AnswerEvaluator()
        evaluator._llm_evaluate = AsyncMock(
            side_effect=AssertionError("fast path should match correct_answer")
        )

        q = _make_open_question(correct_answer="Paris", headline_answer=None)

        result, score = await evaluator.evaluate("paris", q, q.question)

        assert result == "correct"
        assert score == 1.0
