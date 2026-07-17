"""TopUpStage — backfills a pack toward target_count, fails loud below a floor
(issue #103 F5).

Best-of-N generation returns at most `count` questions, and each downstream
stage (`VerificationStage`, `ScoringStage`, `DedupStage`) only ever *drops*
questions — nothing tops the batch back up. Before this stage, a pack that
lost questions to verification/scoring/dedup silently delivered short:
`PersistStage` wrote `actual_count = len(ctx.questions)` and the worker
marked the order `delivered` unconditionally, with no client-visible signal
of the shortfall.

This stage re-runs generation → verification → scoring → dedup for just the
shortfall, up to `max_rounds` extra rounds, merging survivors into
`ctx.questions` each time (the merged list — not just the new batch — goes
through `DedupStage` again so a top-up round can't reintroduce a duplicate
of an already-accepted question). If the pack is still below
`FLOOR_FRACTION * target_count` after every round, it raises instead of
letting the worker mark the order `delivered` — the acceptance bar
(`app/worker/tasks.py`) is "fail loud, don't ship a silently short pack".
"""

from __future__ import annotations

import logging

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink

logger = logging.getLogger(__name__)

# Below this fraction of target_count, the order fails outright rather than
# delivering short. 80% is the floor #103 F5 calls out: a 10-question pack
# that comes back with 7 questions after two top-up rounds is still a
# materially incomplete product a customer paid full price for; below that
# the fix is a fresh generation attempt (a manual/auto retry), not a
# quietly-smaller pack.
FLOOR_FRACTION = 0.8

# Bounded so a persistently low-yield prompt (e.g. an obscure topic that
# keeps failing verification) can't loop the worker indefinitely — two extra
# rounds gives every question in the shortfall two more tries at surviving
# verification/scoring/dedup before the floor check decides the outcome.
MAX_TOPUP_ROUNDS = 2


class TopUpStage:
    """Backfills `ctx.questions` toward `ctx.target_count`; fails below the floor."""

    name = "topup"

    def __init__(
        self,
        generation_stage,
        verification_stage,
        scoring_stage,
        dedup_stage,
        floor_fraction: float = FLOOR_FRACTION,
        max_rounds: int = MAX_TOPUP_ROUNDS,
    ) -> None:
        self._generation_stage = generation_stage
        self._verification_stage = verification_stage
        self._scoring_stage = scoring_stage
        self._dedup_stage = dedup_stage
        self._floor_fraction = floor_fraction
        self._max_rounds = max_rounds

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        target = ctx.target_count
        cost_cents = 0
        rounds = 0

        while len(ctx.questions) < target and rounds < self._max_rounds:
            shortfall = target - len(ctx.questions)
            survivors_so_far = ctx.questions
            original_target = ctx.target_count
            ctx.target_count = shortfall
            try:
                cost_cents += (await self._generation_stage.run(ctx, sink)).cost_cents
                cost_cents += (await self._verification_stage.run(ctx, sink)).cost_cents
                cost_cents += (await self._scoring_stage.run(ctx, sink)).cost_cents
            finally:
                ctx.target_count = original_target

            # Merge before dedup so a top-up round can't reintroduce a
            # near-duplicate of a question already accepted in an earlier
            # round or the initial pass.
            ctx.questions = survivors_so_far + ctx.questions
            cost_cents += (await self._dedup_stage.run(ctx, sink)).cost_cents
            rounds += 1
            logger.info(
                "TopUpStage round=%d shortfall=%d now=%d/%d",
                rounds, shortfall, len(ctx.questions), target,
            )

        final_count = len(ctx.questions)
        floor = self._floor_fraction * target
        if final_count < floor:
            raise ValueError(
                f"pack shortfall: {final_count}/{target} questions survived "
                f"after {rounds} top-up round(s) — below the "
                f"{self._floor_fraction:.0%} floor ({floor:.1f})"
            )

        return StageResult(
            info={
                "final_count": final_count,
                "target_count": target,
                "topup_rounds": rounds,
            },
            cost_cents=cost_cents,
        )
