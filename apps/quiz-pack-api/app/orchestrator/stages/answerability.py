"""AnswerabilityStage — early round-trip answerability gate (#135 D10 / O3).

Runs right after dedup, before verification/scoring, so an unclear or
unanswerable question never pays for Tavily searches or judge calls. One
cheap call per question (``AnswerabilityChecker``); drops are logged with the
checker's own answer so an audit can see WHY the round trip failed. A checker
failure keeps the question (absence of a judgment is not a failed judgment).
Disable the whole stage with ``ANSWERABILITY_CHECK=0``.
"""

from __future__ import annotations

import asyncio
import logging

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.verification.answerability import AnswerabilityChecker

logger = logging.getLogger(__name__)

# Same in-flight bound as the other LLM-fanning stages.
_MAX_CONCURRENT_CHECKS = 8


class AnswerabilityStage:
    """Drops questions a blind cheap model cannot answer (or flags unclear)."""

    name = "answerability"

    def __init__(self, checker: AnswerabilityChecker) -> None:
        self._checker = checker

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        if not ctx.questions:
            return StageResult(info={"checked": 0, "dropped_answerability": 0})

        semaphore = asyncio.Semaphore(_MAX_CONCURRENT_CHECKS)

        async def _check_one(q):
            async with semaphore:
                return await self._checker.check(q)

        results = await asyncio.gather(*(_check_one(q) for q in ctx.questions))

        kept = []
        dropped = 0
        reasons: dict[str, int] = {}
        for q, result in zip(ctx.questions, results):
            if result.passed:
                kept.append(q)
                continue
            dropped += 1
            reasons[result.reason or "unknown"] = (
                reasons.get(result.reason or "unknown", 0) + 1
            )
            logger.warning(
                "AnswerabilityStage dropped id=%s reason=%s model_answer=%r "
                "question=%r",
                q.id,
                result.reason,
                result.model_answer,
                q.question[:100],
            )

        ctx.questions = kept
        return StageResult(
            info={
                "checked": len(results),
                "dropped_answerability": dropped,
                **{f"dropped_{k}": v for k, v in sorted(reasons.items())},
            },
            cost_cents=0,
        )
