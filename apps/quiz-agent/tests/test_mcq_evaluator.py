"""Tests for the MCQ fast-path of the production answer evaluator.

Every matching assertion below runs the REAL
``AnswerEvaluator._evaluate_mcq`` (app/evaluation/evaluator.py) and the REAL
``quiz_shared.utils.text_normalization.normalize_text``. This file used to hold
inline copies of both, so the whole suite stayed green even if the production
matcher was deleted — the option-matching rules the player's score depends on
had zero real coverage.

Also pins the routing contract the fast-path hangs off (``if
question.possible_answers:`` — presence of options, NOT ``question.type``) and
the "MCQ never pays partial credit" rule.
"""

import os

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

from unittest.mock import AsyncMock  # noqa: E402

import pytest  # noqa: E402

from app.evaluation.evaluator import AnswerEvaluator  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402
from quiz_shared.utils.text_normalization import normalize_text  # noqa: E402

OPTIONS = {"a": "Paris", "b": "London", "c": "Berlin", "d": "Madrid"}


def _question(
    correct_answer="a",
    possible_answers=OPTIONS,
    qtype: str = "text_multichoice",
) -> Question:
    return Question(
        id="q_mcq",
        question="What is the capital of France?",
        type=qtype,
        possible_answers=possible_answers,
        correct_answer=correct_answer,
        topic="Geography",
        category="general",
        difficulty="easy",
    )


@pytest.fixture
def evaluator() -> AnswerEvaluator:
    """A real evaluator. Its LLM client is never used by the MCQ fast-path —
    any test that reaches it is a routing bug, and says so explicitly."""
    return AnswerEvaluator()


def _mcq(evaluator: AnswerEvaluator, user_answer: str, correct_answer="a", **kwargs):
    """One call into the production matcher."""
    return evaluator._evaluate_mcq(
        user_answer, _question(correct_answer=correct_answer, **kwargs)
    )


class TestMCQEvaluator:
    """Option resolution: a spoken answer may arrive as a key or as option text."""

    def test_correct_by_key(self, evaluator):
        assert _mcq(evaluator, "a") == ("correct", 1.0)

    def test_correct_by_key_uppercase(self, evaluator):
        """iOS submits whatever was transcribed; casing must not lose a point."""
        assert _mcq(evaluator, "A") == ("correct", 1.0)

    def test_correct_by_value(self, evaluator):
        """Players speak the option, not the letter."""
        assert _mcq(evaluator, "Paris") == ("correct", 1.0)

    def test_correct_by_value_case_insensitive(self, evaluator):
        assert _mcq(evaluator, "paris") == ("correct", 1.0)

    def test_incorrect_by_key(self, evaluator):
        assert _mcq(evaluator, "b") == ("incorrect", 0.0)

    def test_incorrect_by_value(self, evaluator):
        assert _mcq(evaluator, "London") == ("incorrect", 0.0)

    def test_no_match_returns_incorrect(self, evaluator):
        """An answer that is not one of the options is wrong, not an error."""
        assert _mcq(evaluator, "Tokyo") == ("incorrect", 0.0)

    def test_correct_answer_stored_as_value(self, evaluator):
        """The corpus stores ``correct_answer`` as the option TEXT on some rows
        (2026-07-12 pilot fix) — key resolution must handle both shapes or every
        one of those questions grades every answer wrong."""
        assert _mcq(evaluator, "a", correct_answer="Paris") == ("correct", 1.0)

    def test_correct_answer_stored_as_value_matched_by_value(self, evaluator):
        assert _mcq(evaluator, "Paris", correct_answer="Paris") == ("correct", 1.0)

    def test_incorrect_when_correct_stored_as_value(self, evaluator):
        assert _mcq(evaluator, "b", correct_answer="Paris") == ("incorrect", 0.0)

    def test_correct_answer_stored_as_list_uses_first_entry(self, evaluator):
        """``correct_answer`` is ``str | list`` on the model; the list shape must
        resolve to its first entry, not stringify into an unmatchable key."""
        assert _mcq(evaluator, "b", correct_answer=["b", "c"]) == ("correct", 1.0)

    def test_empty_answer_matches_no_option(self, evaluator):
        assert _mcq(evaluator, "") == ("incorrect", 0.0)

    @pytest.mark.asyncio
    async def test_empty_answer_is_skipped_before_reaching_the_matcher(self, evaluator):
        """Through the public path an empty submit is a SKIP, not a wrong answer:
        the player said nothing, so they get no verdict and no penalty. The MCQ
        matcher (which would call it "incorrect") is never reached."""
        result, score = await evaluator.evaluate("", _question())
        assert (result, score) == ("skipped", 0.0)

    def test_normalization_is_the_shared_production_one(self):
        """The matcher normalizes via ``quiz_shared`` — punctuation and spacing
        are stripped, so "Paris," and " paris " select the same option."""
        assert normalize_text("Paris, France!") == "paris france"
        assert normalize_text("  London  ") == "london"


class TestMCQEvaluatorSlovakGap:
    """Backend `_evaluate_mcq` does NOT translate Slovak ordinals / letter-forms.

    Raw transcript tokens like "jedna" (one), "dva" (two), "áčko" (A-form),
    "pričko" (intentional non-Slovak / typo) cannot match keys (`a`–`d`) or
    English values, so the backend returns "incorrect". This is the gap that
    Track E task 42.15 (`MCQTranscriptMatcher` in `QuizViewModel+Recording.swift`)
    is responsible for closing — the iOS layer normalizes the transcript to a
    key letter BEFORE submitting to the API.

    These tests pin the current contract: backend stays English-only; iOS owns
    transcript → option resolution. If a future change adds Slovak handling
    server-side, these tests fail loud and the iOS matcher can be simplified.
    """

    @pytest.mark.parametrize(
        "token",
        ["jedna", "dva", "áčko", "pričko"],
    )
    def test_slovak_tokens_not_matched_backend_side(self, evaluator, token):
        result, score = _mcq(evaluator, token)
        assert result == "incorrect"
        assert score == 0.0


class TestMCQAwardsNoPartialCredit:
    """MCQ is all-or-nothing (``_evaluate_mcq`` docstring: "No partial credit
    for MCQ — user picked from finite options").

    The 0.5 / 0.25 weights in ``evaluate``'s ``score_map`` exist for free-text
    answers judged by the LLM. If an MCQ ever reached that judge, a
    plausible-but-wrong option ("London" for "Paris") would earn half a point,
    and the freemium score would drift away from "questions answered correctly".
    """

    @pytest.mark.asyncio
    async def test_wrong_option_scores_zero_and_never_consults_the_judge(
        self, evaluator
    ):
        evaluator._llm_evaluate = AsyncMock(
            side_effect=AssertionError(
                "the LLM judge (the only source of 0.5/0.25) must never see an MCQ"
            )
        )

        result, score = await evaluator.evaluate("London", _question())

        assert (result, score) == ("incorrect", 0.0)
        assert score not in (0.25, 0.5)
        assert evaluator._llm_evaluate.await_count == 0

    @pytest.mark.asyncio
    async def test_partially_spoken_option_is_not_half_credit(self, evaluator):
        """Saying "Paris France" is not selecting one of the options: MCQ
        resolution is exact (post-normalization), so a near-miss scores 0.0
        rather than partial credit."""
        result, score = await evaluator.evaluate("Paris France", _question())

        assert (result, score) == ("incorrect", 0.0)


class TestEvaluatorRoutingByPossibleAnswers:
    """Pin the routing contract in ``evaluate`` (``if question.possible_answers:``).

    The MCQ fast-path fires on presence of options, NOT on ``question.type``:

    * A question with ``type="text_multichoice"`` but ``possible_answers=None``
      must NOT hit the MCQ branch (otherwise the fast-path would dereference
      ``None`` and crash). It must fall through to the LLM evaluator, where the
      LLM/normalization layers degrade gracefully. The 42.9a stage-level filter
      is the only line of defense against this shape leaking out of generation;
      this test makes the contract surface explicit so the filter cannot be
      quietly removed.
    * A question with ``type="text"`` but populated ``possible_answers`` MUST
      take the MCQ fast-path — i.e. options-in-text questions converted by
      42.11 don't need their ``type`` migrated to evaluate as MCQ.
    """

    @pytest.mark.asyncio
    async def test_text_multichoice_with_none_options_falls_through_to_llm(
        self, evaluator
    ):
        evaluator._llm_evaluate = AsyncMock(return_value="incorrect")
        evaluator._evaluate_mcq = AsyncMock(
            side_effect=AssertionError(
                "MCQ fast-path must not fire when possible_answers is None"
            )
        )

        q = _question(qtype="text_multichoice", possible_answers=None)
        result, score = await evaluator.evaluate("Paris", q, q.question)

        assert evaluator._llm_evaluate.await_count == 1
        assert evaluator._evaluate_mcq.await_count == 0
        assert result == "incorrect"
        assert score == 0.0

    @pytest.mark.asyncio
    async def test_text_type_with_options_hits_mcq_fast_path(self, evaluator):
        evaluator._llm_evaluate = AsyncMock(
            side_effect=AssertionError(
                "LLM path must not fire when possible_answers is populated"
            )
        )

        q = _question(qtype="text", possible_answers=OPTIONS)
        result, score = await evaluator.evaluate("b", q, q.question)

        assert evaluator._llm_evaluate.await_count == 0
        assert result == "incorrect"
        assert score == 0.0
