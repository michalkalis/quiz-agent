"""pgvector round-trip regression for MCQ (issue #50, task 50.3).

Tests _question_to_row_dict and _row_to_question using plain Python dicts —
no live Postgres required.  Proves that type, possible_answers, and
correct_answer survive the row round-trip so the evaluator fast-path and
the iOS option picker are not silently broken by a store layer that drops
MCQ fields.

Why it matters: the evaluator fast-path fires on possible_answers presence
(evaluator.py:83).  If the store silently drops possible_answers an MCQ
question degrades to LLM free-text evaluation and iOS gets no option list.
"""

from datetime import datetime, timezone

from quiz_shared.database.pgvector_client import (
    _question_to_row_dict,
    _row_to_question,
)
from quiz_shared.models.question import Question


_MCQ_QUESTION = Question(
    id="q_mcq_roundtrip_test",
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


def test_mcq_row_dict_captures_all_three_mcq_fields():
    """_question_to_row_dict must preserve type, possible_answers, correct_answer."""
    row = _question_to_row_dict(_MCQ_QUESTION, embedding=None)

    assert row["type"] == "text_multichoice"
    assert row["possible_answers"] == {
        "a": "Paris",
        "b": "London",
        "c": "Berlin",
        "d": "Madrid",
    }
    assert row["correct_answer"] == "b"


def test_mcq_fields_survive_full_roundtrip():
    """type, possible_answers, and correct_answer must survive dict → Question exactly."""
    row = _question_to_row_dict(_MCQ_QUESTION, embedding=None)
    restored = _row_to_question(row)

    assert restored.type == "text_multichoice"
    assert restored.possible_answers == {
        "a": "Paris",
        "b": "London",
        "c": "Berlin",
        "d": "Madrid",
    }
    assert restored.correct_answer == "b"
