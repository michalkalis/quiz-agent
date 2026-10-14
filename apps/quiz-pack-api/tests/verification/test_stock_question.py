"""Tests for the #203 stock-question check.

Why these tests matter:
- The verdict decides whether a question leaves the corpus, so a misaligned
  index would archive the wrong question: verdicts must land on the item the
  model numbered.
- Fail-safe contract shared by every check: a dead call or garbled answer must
  never mark anything stock (``None`` = keep), or an outage would empty a
  category.
"""

from __future__ import annotations

import pytest

from app.verification.stock_question import StockQuestionChecker
from quiz_shared.models.question import Question


def _q(text: str, answer: str = "x") -> Question:
    return Question.from_dict(
        {
            "id": f"q-{abs(hash(text))}",
            "question": text,
            "type": "text",
            "correct_answer": answer,
            "topic": "History",
            "category": "history",
            "difficulty": "easy",
        }
    )


def test_verdicts_align_to_model_index_not_response_order():
    text = (
        '{"verdicts": [{"index": 2, "stock": true, "reason": "Rosa Parks staple"},'
        ' {"index": 1, "stock": false, "reason": "fresh angle"}]}'
    )
    result = StockQuestionChecker.parse(text, 2)
    assert result[0].stock is False
    assert result[1].stock is True and "Rosa Parks" in result[1].reason


@pytest.mark.parametrize(
    "text",
    [
        "no json at all",
        '{"verdicts": [',
        '{"verdicts": [{"index": 5, "stock": true}]}',  # out of range
        '{"verdicts": [{"index": 1, "stock": "yes"}]}',  # not a bool
    ],
)
def test_unusable_answers_keep_every_question(text):
    assert StockQuestionChecker.parse(text, 2) == [None, None]


async def test_dead_call_keeps_every_question(monkeypatch):
    checker = StockQuestionChecker(model="stub")

    async def dead(_prompt):
        return None

    monkeypatch.setattr(checker, "_complete", dead)
    assert await checker.check([_q("a"), _q("b")]) == [None, None]


def test_prompt_numbers_questions_and_shows_options():
    mcq = _q("Which planet is hotter?", "b")
    mcq.possible_answers = {"a": "Mercury", "b": "Venus"}
    prompt = StockQuestionChecker.build_prompt([_q("Who was first?"), mcq])
    assert "1. Q: Who was first?" in prompt
    assert "2. Q: Which planet is hotter?" in prompt
    assert "Mercury | Venus" in prompt
