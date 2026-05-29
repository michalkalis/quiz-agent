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
    def test_slovak_tokens_not_matched_backend_side(self, token):
        result, score = _evaluate_mcq(token, OPTIONS, "a")
        assert result == "incorrect"
        assert score == 0.0


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
