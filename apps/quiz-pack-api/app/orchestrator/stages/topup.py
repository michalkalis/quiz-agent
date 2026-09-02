"""TopUpStage — backfills a pack toward target_count, fails loud below a floor
(issue #103 F5).

Best-of-N generation returns at most `count` questions, and each downstream
stage (`VerificationStage`, `ScoringStage`, `DedupStage`) only ever *drops*
questions — nothing tops the batch back up. Before this stage, a pack that
lost questions to verification/scoring/dedup silently delivered short:
`PersistStage` wrote `actual_count = len(ctx.questions)` and the worker
marked the order `delivered` unconditionally, with no client-visible signal
of the shortfall.

This stage re-runs generation → dedup → verification → scoring for just the
shortfall, up to `max_rounds` extra rounds, merging survivors into
`ctx.questions` before dedup each time (the merged list — not just the new
batch — goes through `DedupStage` again so a top-up round can't reintroduce
a duplicate of an already-accepted question). If the pack is still below
`FLOOR_FRACTION * target_count` after every round, it raises instead of
letting the worker mark the order `delivered` — the acceptance bar
(`app/worker/tasks.py`) is "fail loud, don't ship a silently short pack".

Dedup runs before verify/score (perf fix, 2026-08): DedupStage never drops a
question it has already accepted in an earlier round — the corpus/gold data
it reads is unchanged for the life of an order, so it is idempotent on the
same input. That means the merged list's already-accepted prefix always
survives dedup unchanged, so only the new (dedup-filtered) batch needs to
pay for verify/score each round, not the whole merged list.

Spent facts are excluded from each round's fact pool (#167, founder directive
2026-09-02): a fact already backing a surviving question can only produce a
question dedup will drop as same-fact reuse, so feeding it to the generator
again buys a guaranteed-dead question at full generation + fact-check price.
See `app.orchestrator.stages.spent_facts` for the predicate, which mirrors
DedupStage's own same-fact logic. The initial round is untouched (no kept
questions exist yet, so nothing is spent).
"""

from __future__ import annotations

import logging

from app import llm_usage
from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.orchestrator.stages.spent_facts import filter_spent_facts

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


async def _run_substage(stage, ctx: OrderContext, sink: ProgressSink) -> StageResult:
    """Run one inner sub-stage with `llm_usage.current_stage` pointed at its
    own name (#153 Phase 0.5) — without this, every LLM call inside a top-up
    round would attribute to "topup" instead of generation/verify/scoring,
    exactly like the main walk."""
    token = llm_usage.current_stage.set(stage.name)
    try:
        return await stage.run(ctx, sink)
    finally:
        llm_usage.current_stage.reset(token)


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
        answerability_stage=None,
        composition_stage=None,
    ) -> None:
        self._generation_stage = generation_stage
        self._verification_stage = verification_stage
        self._scoring_stage = scoring_stage
        self._dedup_stage = dedup_stage
        # #135 D10 — optional; when present, top-up rounds re-apply the
        # round-trip check to the new tail, mirroring the main walk's
        # dedup → answerability → verify → score order.
        self._answerability_stage = answerability_stage
        # #153 Phase 0.1 — optional; batch-composition caps (per-topic, T/F)
        # are batch-level properties, so unlike verify/score they re-run on
        # the FULL merged set after each round, not just the new tail.
        self._composition_stage = composition_stage
        self._floor_fraction = floor_fraction
        self._max_rounds = max_rounds

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        target = ctx.target_count
        cost_cents = 0
        rounds = 0
        # Recomputed from the FULL pool each round rather than shrunk in place:
        # later stages (composition caps) can drop a survivor, which un-spends
        # its fact, and only a recompute against the current `ctx.questions`
        # stays in step with what dedup will actually compare against.
        original_facts = ctx.facts
        exhausted = False

        while len(ctx.questions) < target and rounds < self._max_rounds:
            shortfall = target - len(ctx.questions)
            survivors_so_far = ctx.questions
            n_old = len(survivors_so_far)
            original_target = ctx.target_count
            round_facts = original_facts
            if original_facts:
                round_facts, spent = filter_spent_facts(
                    original_facts, survivors_so_far
                )
                logger.info(
                    "TopUpStage round=%d fact pool: %d spent, %d remain",
                    rounds + 1, spent, len(round_facts),
                )
                if not round_facts:
                    logger.warning(
                        "TopUpStage round=%d skipped: fact pool exhausted — "
                        "top-up round would only produce dedup-doomed "
                        "questions (%d/%d facts already spent)",
                        rounds + 1, spent, len(original_facts),
                    )
                    exhausted = True
                    break
            ctx.target_count = shortfall
            ctx.facts = round_facts
            try:
                cost_cents += (
                    await _run_substage(self._generation_stage, ctx, sink)
                ).cost_cents
            finally:
                ctx.target_count = original_target
                ctx.facts = original_facts

            # Merge before dedup so a top-up round can't reintroduce a
            # near-duplicate of a question already accepted in an earlier
            # round or the initial pass.
            ctx.questions = survivors_so_far + ctx.questions
            cost_cents += (await _run_substage(self._dedup_stage, ctx, sink)).cost_cents

            # DedupStage is idempotent on already-accepted survivors (see
            # module docstring), so the surviving list's first `n_old`
            # entries are exactly `survivors_so_far`, unchanged. Only the new
            # (now dedup-filtered) tail needs to pay for verify/score.
            old_kept = ctx.questions[:n_old]
            ctx.questions = ctx.questions[n_old:]
            if self._answerability_stage is not None:
                cost_cents += (
                    await _run_substage(self._answerability_stage, ctx, sink)
                ).cost_cents
            cost_cents += (
                await _run_substage(self._verification_stage, ctx, sink)
            ).cost_cents
            cost_cents += (
                await _run_substage(self._scoring_stage, ctx, sink)
            ).cost_cents
            ctx.questions = old_kept + ctx.questions
            if self._composition_stage is not None:
                cost_cents += (
                    await _run_substage(self._composition_stage, ctx, sink)
                ).cost_cents
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
                "fact_pool_exhausted": exhausted,
            },
            cost_cents=cost_cents,
        )
