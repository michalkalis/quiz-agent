"""Serializer contract test for MCQ (issue #50, task 50.4).

Tests question_to_dict with a text_multichoice question.  Pins two API
contract requirements:
  1. type and possible_answers are present in the client payload.
  2. correct_answer is ABSENT — leaking it to the client would make the
     answer key trivially exploitable, and iOS routes to MCQOptionPicker
     based on type + options without needing the answer.

Why it matters: iOS (#45) routes to MCQOptionPicker on type + options; this
test is the backend half of that API contract.
"""

from datetime import datetime, timezone

from quiz_shared.models.question import Question

from app.serializers import question_to_dict


_MCQ_QUESTION = Question(
    id="q_mcq_serializer_test",
    question="What is the capital of France?",
    type="text_multichoice",
    possible_answers={"a": "Paris", "b": "London", "c": "Berlin", "d": "Madrid"},
    correct_answer="b",
    topic="Geography",
    category="adults",
    difficulty="easy",
    review_status="approved",
    created_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
)


def test_question_to_dict_includes_type_and_possible_answers():
    """MCQ type and all options must be present in the API response."""
    result = question_to_dict(_MCQ_QUESTION)

    assert result["type"] == "text_multichoice"
    assert result["possible_answers"] == {
        "a": "Paris",
        "b": "London",
        "c": "Berlin",
        "d": "Madrid",
    }


def test_question_to_dict_excludes_correct_answer():
    """correct_answer must never appear in the client payload — MCQ makes a leak instantly exploitable."""
    result = question_to_dict(_MCQ_QUESTION)

    assert "correct_answer" not in result
