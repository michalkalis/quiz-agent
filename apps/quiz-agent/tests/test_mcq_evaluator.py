"""Tests for MCQ fast-path evaluator.

Tests the MCQ matching logic with an inline copy of normalize_text, plus a
routing-by-`possible_answers` regression test that exercises the real
``AnswerEvaluator.evaluate`` against the contract documented at
``evaluator.py:77``: the MCQ fast-path triggers on presence of
``possible_answers`` — NOT on ``question.type``.
"""

import os
import re
from unittest.mock import AsyncMock

import pytest

os.environ.setdefault("OPENAI_API_KEY", "sk-test")


def normalize_text(text: str) -> str:
    """Copy of quiz_shared.utils.text_normalization.normalize_text."""
    text = text.lower().strip()
    text = re.sub(r'[.,!?;:\'"()-]', "", text)
    text = re.sub(r"\s+", " ", text)
    return text


def _evaluate_mcq(user_answer: str, possible_answers: dict, correct_answer: str):
    """Mirror of AnswerEvaluator._evaluate_mcq for isolated testing."""
    normalized = normalize_text(user_answer)

    selected_key = None
    for key, value in possible_answers.items():
        if normalized == normalize_text(key) or normalized == normalize_text(value):
            selected_key = key
            break

    if selected_key is None:
        return "incorrect", 0.0

    correct_key = correct_answer
    if correct_key not in possible_answers:
        for key, value in possible_answers.items():
            if normalize_text(str(correct_answer)) == normalize_text(value):
                correct_key = key
                break

    return ("correct", 1.0) if selected_key == correct_key else ("incorrect", 0.0)


OPTIONS = {"a": "Paris", "b": "London", "c": "Berlin", "d": "Madrid"}


class TestMCQEvaluator:
    def test_correct_by_key(self):
        assert _evaluate_mcq("a", OPTIONS, "a") == ("correct", 1.0)

    def test_correct_by_key_uppercase(self):
        assert _evaluate_mcq("A", OPTIONS, "a") == ("correct", 1.0)

    def test_correct_by_value(self):
        assert _evaluate_mcq("Paris", OPTIONS, "a") == ("correct", 1.0)

    def test_correct_by_value_case_insensitive(self):
        assert _evaluate_mcq("paris", OPTIONS, "a") == ("correct", 1.0)

    def test_incorrect_by_key(self):
        assert _evaluate_mcq("b", OPTIONS, "a") == ("incorrect", 0.0)

    def test_incorrect_by_value(self):
        assert _evaluate_mcq("London", OPTIONS, "a") == ("incorrect", 0.0)

    def test_no_match_returns_incorrect(self):
        assert _evaluate_mcq("Tokyo", OPTIONS, "a") == ("incorrect", 0.0)

    def test_correct_answer_stored_as_value(self):
        """correct_answer is 'Paris' (value) instead of 'a' (key)."""
        assert _evaluate_mcq("a", OPTIONS, "Paris") == ("correct", 1.0)

    def test_correct_answer_stored_as_value_matched_by_value(self):
        assert _evaluate_mcq("Paris", OPTIONS, "Paris") == ("correct", 1.0)

    def test_incorrect_when_correct_stored_as_value(self):
        assert _evaluate_mcq("b", OPTIONS, "Paris") == ("incorrect", 0.0)

    def test_empty_answer(self):
        assert _evaluate_mcq("", OPTIONS, "a") == ("incorrect", 0.0)


class TestMCQEvaluatorResolvesSpokenReferences:
    """The backend no longer leaves Slovak transcript → option resolution to iOS.

    This class used to pin the opposite contract ("backend stays English-only;
    iOS owns transcript → option resolution") and predicted its own reversal:
    iOS only resolves on the streaming STT path, so once the app started reading
    the options aloud, every other path delivered "áčko" to a backend that
    scored it incorrect. ``spoken_options.resolve_spoken_option`` closed that;
    these tests now run the REAL ``_evaluate_mcq`` rather than the mirror above,
    because a mirror cannot fail when the production branch changes.
    """

    def _evaluate(self, token: str, correct_answer: str = "a"):
        from app.evaluation.evaluator import AnswerEvaluator
        from quiz_shared.models.question import Question

        question = Question(
            id="q_test",
            question="What is the capital of France?",
            type="text_multichoice",
            possible_answers=OPTIONS,
            correct_answer=correct_answer,
            topic="Geography",
            category="adults",
            difficulty="easy",
        )
        return AnswerEvaluator()._evaluate_mcq(token, question)

    @pytest.mark.parametrize("token", ["jedna", "áčko", "acko"])
    def test_slovak_reference_to_the_correct_option_now_scores(self, token):
        assert self._evaluate(token) == ("correct", 1.0)

    @pytest.mark.parametrize("token", ["dva", "béčko"])
    def test_slovak_reference_to_a_wrong_option_scores_that_option(self, token):
        """Naming option B must score B — worth nothing here, everything there.

        Asserting only the wrong-answer case would pass even if the token were
        never understood at all, since an unresolved utterance also scores
        ("incorrect", 0.0). Flipping which option is correct is what proves the
        reference actually landed on B.
        """
        assert self._evaluate(token, correct_answer="a") == ("incorrect", 0.0)
        assert self._evaluate(token, correct_answer="b") == ("correct", 1.0)

    def test_non_slovak_lookalike_is_still_not_matched(self):
        """A near-miss of a letter-name must not be guessed into an option."""
        assert self._evaluate("pričko") == ("incorrect", 0.0)


class TestEvaluatorRoutingByPossibleAnswers:
    """Pin the routing contract at ``evaluator.py:77``.

    The MCQ fast-path fires on ``if question.possible_answers:`` — presence of
    options, NOT on ``question.type``. This means:

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

    def _make_question(self, *, qtype: str, possible_answers):
        from quiz_shared.models.question import Question

        return Question(
            id="q_test",
            question="Is Paris the capital of France?",
            type=qtype,
            possible_answers=possible_answers,
            correct_answer="a",
            topic="Geography",
            category="adults",
            difficulty="easy",
        )

    @pytest.mark.asyncio
    async def test_text_multichoice_with_none_options_falls_through_to_llm(self):
        from app.evaluation.evaluator import AnswerEvaluator

        evaluator = AnswerEvaluator()
        evaluator._llm_evaluate = AsyncMock(return_value="incorrect")
        evaluator._evaluate_mcq = AsyncMock(
            side_effect=AssertionError(
                "MCQ fast-path must not fire when possible_answers is None"
            )
        )

        q = self._make_question(qtype="text_multichoice", possible_answers=None)
        result, score = await evaluator.evaluate("Paris", q, q.question)

        assert evaluator._llm_evaluate.await_count == 1
        assert evaluator._evaluate_mcq.await_count == 0
        assert result == "incorrect"
        assert score == 0.0

    @pytest.mark.asyncio
    async def test_text_type_with_options_hits_mcq_fast_path(self):
        from app.evaluation.evaluator import AnswerEvaluator

        evaluator = AnswerEvaluator()
        evaluator._llm_evaluate = AsyncMock(
            side_effect=AssertionError(
                "LLM path must not fire when possible_answers is populated"
            )
        )

        q = self._make_question(qtype="text", possible_answers=OPTIONS)
        result, score = await evaluator.evaluate("b", q, q.question)

        assert evaluator._llm_evaluate.await_count == 0
        assert result == "incorrect"
        assert score == 0.0
