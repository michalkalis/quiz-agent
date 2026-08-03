"""#135 D10 — AnswerabilityStage: early drop, fail-safe keep, audit info.

The stage sits between dedup and verification so an unanswerable question
never pays for Tavily/judge calls. What matters: failed checks drop, passed
and fail-safe results keep, and the StageResult info carries the counts the
SSE/audit clients read (mirroring the other stages' contracts).
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest

from app.orchestrator.context import OrderContext
from app.orchestrator.stages.answerability import AnswerabilityStage
from app.verification.answerability import AnswerabilityResult
from quiz_shared.models.question import Question


class _StubChecker:
    def __init__(self, results: dict[str, AnswerabilityResult]):
        self._results = results
        self.checked: list[str] = []

    async def check(self, question: Question) -> AnswerabilityResult:
        self.checked.append(question.id)
        return self._results.get(question.id, AnswerabilityResult(passed=True))


class _NullSink:
    async def start_step(self, *a: Any, **k: Any) -> int:
        return 0

    async def publish(self, *a: Any, **k: Any) -> None:
        return None


def _question(idx: int) -> Question:
    return Question(
        id=f"q_{idx}",
        question=f"stub question {idx}",
        correct_answer="answer",
        topic="General",
        category="general",
        difficulty="medium",
    )


def _ctx(questions: list[Question]) -> OrderContext:
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="stub",
        language="en",
        target_count=len(questions),
    )
    ctx.questions = list(questions)
    return ctx


@pytest.mark.asyncio
async def test_stage_drops_failed_keeps_passed_and_unavailable() -> None:
    questions = [_question(i) for i in range(4)]
    checker = _StubChecker(
        {
            "q_1": AnswerabilityResult(passed=False, reason="wrong_answer", model_answer="x"),
            "q_2": AnswerabilityResult(passed=True, reason="check_unavailable"),
            "q_3": AnswerabilityResult(passed=False, reason="flagged_ambiguous"),
        }
    )
    ctx = _ctx(questions)
    result = await AnswerabilityStage(checker).run(ctx, _NullSink())

    assert [q.id for q in ctx.questions] == ["q_0", "q_2"]
    assert result.info["checked"] == 4
    assert result.info["dropped_answerability"] == 2
    assert result.info["dropped_wrong_answer"] == 1
    assert result.info["dropped_flagged_ambiguous"] == 1
    assert sorted(checker.checked) == ["q_0", "q_1", "q_2", "q_3"]


@pytest.mark.asyncio
async def test_stage_noop_on_empty_batch() -> None:
    checker = _StubChecker({})
    ctx = _ctx([])
    result = await AnswerabilityStage(checker).run(ctx, _NullSink())
    assert result.info == {"checked": 0, "dropped_answerability": 0}
    assert checker.checked == []
