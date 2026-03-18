"""Tests for MCQ fast-path evaluator.

Tests the MCQ matching logic with an inline copy of normalize_text,
avoiding heavy transitive deps (langchain, numpy) not installed
in the lightweight test environment.
"""

import re


def normalize_text(text: str) -> str:
    """Copy of quiz_shared.utils.text_normalization.normalize_text."""
    text = text.lower().strip()
    text = re.sub(r'[.,!?;:\'"()-]', '', text)
    text = re.sub(r'\s+', ' ', text)
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
