"""ARQ task: `process_order` — drives an order through `PackGenerator`.

Issue #36 task 2.10 replaced the Phase-1 stub with a real orchestrator
walk. The stages (sourcing → generating → dedup → verifying → scoring →
top-up → persisting) live in ``app/orchestrator/stages``; this module wires
them to the ARQ ``ctx`` collaborators built in ``app.worker.worker.on_startup``
and handles the worker-layer concerns the orchestrator deliberately
omits: order/job row updates, cost-cents accounting, retry semantics,
and the final ``done`` event SSE clients expect.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Dict

import sentry_sdk

from app import cost_tracking, order_budget
from app.db.models import GenerationJob, GenerationOrder
from app.db.session import AsyncSessionLocal
from app.orchestrator import PackGenerator
from app.orchestrator.pack_generator import Stage
from app.orchestrator.progress_sink import DBProgressSink
from app.orchestrator.stages import (
    AnswerabilityStage,
    DedupStage,
    GenerationStage,
    PersistStage,
    ScoringStage,
    SourcingStage,
    TopUpStage,
    VerificationStage,
)

logger = logging.getLogger(__name__)

# #139 — the sweep measures job liveness via `generation_jobs.updated_at`,
# which historically only moved on step appends. A legit frontier pack_30
# spends 10+ minutes inside ONE stage, so the 15-minute staleness threshold
# would have re-enqueued a live job (double-billing a purchase). This
# heartbeat touches the row every 60s while the pipeline runs.
HEARTBEAT_INTERVAL_SECONDS = 60.0


def _now() -> datetime:
    return datetime.now(timezone.utc)


async def _job_heartbeat(session_factory: Any, job_id: uuid.UUID) -> None:
    from sqlalchemy import text

    while True:
        await asyncio.sleep(HEARTBEAT_INTERVAL_SECONDS)
        try:
            async with session_factory() as session:
                await session.execute(
                    text("UPDATE generation_jobs SET updated_at = now() WHERE id = :id"),
                    {"id": job_id},
                )
                await session.commit()
        except Exception:
            # A missed beat must never kill the pipeline; the next one retries.
            logger.warning("job heartbeat failed job_id=%s", job_id, exc_info=True)


def _build_stages(ctx: Dict[str, Any]) -> list[Stage]:
    """Compose the Phase-2 stages from collaborators on ARQ ctx.

    #103 F5: TopUpStage reuses the SAME generation/verification/scoring/dedup
    stage instances for its backfill rounds (not fresh copies) — same
    collaborators, same config, so a top-up round behaves identically to the
    initial pass.

    2026-08 perf fix: dedup runs right after generation, before verification
    (1 call/q) and scoring — a question dedup would discard anyway should
    never pay for either. #135 D10: the answerability round-trip check sits
    between dedup and verification (EARLY, one cheap call/q) so an unclear or
    unanswerable question never pays for Tavily/judges either; absent from
    the walk entirely when ``ANSWERABILITY_CHECK=0`` or no checker is on ctx.
    """
    from app import feature_flags

    session_factory = ctx.get("session_factory") or AsyncSessionLocal
    generation = GenerationStage(
        ctx["generator"],
        ctx.get("answer_normalizer"),
        expiry_classifier=ctx.get("expiry_classifier"),
    )
    verification = VerificationStage(ctx["fact_verifier"], ctx.get("logical_verifier"))
    scoring = ScoringStage(ctx["scorer"])
    dedup = DedupStage(ctx["question_store"], ctx.get("gold_standard_path"))
    answerability = None
    if feature_flags.answerability_check() and ctx.get("answerability_checker"):
        answerability = AnswerabilityStage(ctx["answerability_checker"])
    stages: list[Stage] = [
        SourcingStage(ctx["fact_sourcer"]),
        generation,
        dedup,
    ]
    if answerability is not None:
        stages.append(answerability)
    stages += [
        verification,
        scoring,
        TopUpStage(
            generation,
            verification,
            scoring,
            dedup,
            answerability_stage=answerability,
        ),
        PersistStage(session_factory),
    ]
    return stages


async def process_order(ctx: Dict[str, Any], order_id: str) -> None:
    """Run a GenerationOrder through the PackGenerator pipeline.

    ctx keys consumed:
    - ctx["redis"]              arq.connections.ArqRedis — pubsub publish
    - ctx["job_try"]            int — current attempt (1-based)
    - ctx["fact_sourcer"], ctx["generator"], ctx["fact_verifier"],
      ctx["scorer"], ctx["question_store"], ctx["gold_standard_path"],
      ctx["session_factory"]    populated by `on_startup` in worker.py
    """
    order_uuid = uuid.UUID(order_id)
    channel = f"order:{order_id}:progress"
    redis = ctx["redis"]
    session_factory = ctx.get("session_factory") or AsyncSessionLocal
    sink: DBProgressSink | None = None
    generator: PackGenerator | None = None
    heartbeat: asyncio.Task[None] | None = None
    tracker: cost_tracking.OrderCostTracker | None = None
    usage_before: float | None = None

    logger.info(
        "process_order start order_id=%s attempt=%s",
        order_id, ctx.get("job_try", 1),
    )

    try:
        async with session_factory() as session:
            order = await session.get(GenerationOrder, order_uuid)
            if order is None:
                raise LookupError(f"GenerationOrder {order_id} not found")
            job_id = order.job_id
            # #145: the budget gate for ARQ's OWN in-sequence retries. The
            # endpoint and the sweep check the same verdict before enqueuing,
            # but ARQ re-runs a raised job without consulting either — so
            # without this check the ceiling could be crossed by two more paid
            # attempts after the order had already been cut off.
            job = await session.get(GenerationJob, job_id) if job_id else None
            if job is not None:
                verdict = order_budget.evaluate(order, job)
                if not verdict.ok:
                    order_budget.mark_exhausted(order, job, verdict)
                    step_log_tail = list(job.step_log or [])[-10:]
                    await session.commit()
                    order_budget.report_breach(order_id, verdict, step_log_tail)
                    return
            if order.status != "in_progress":
                order.status = "in_progress"
                await session.commit()

        heartbeat = asyncio.create_task(_job_heartbeat(session_factory, job_id))

        sink = DBProgressSink(session_factory, redis, channel, job_id)
        sink_factory = _make_sink_factory(sink)

        stages = _build_stages(ctx)
        generator = PackGenerator(stages=stages, sink_factory=sink_factory)

        async with session_factory() as session:
            order = await session.get(GenerationOrder, order_uuid)
            if order is None:
                raise LookupError(f"GenerationOrder {order_id} not found")
            order_snapshot = order  # detached enough for read-only stage access
            session.expunge(order_snapshot)

        # Cost capture (#95 decision 5): Tavily calls report into the tracker
        # as they happen; the OpenRouter account-usage snapshots bracket the
        # run so their delta is the measured all-in LLM spend for this order
        # (see app.cost_tracking for the shared-account caveat).
        tracker, tracker_token = cost_tracking.activate()
        usage_before = await cost_tracking.fetch_openrouter_usage()
        try:
            pack = await generator.run(order_snapshot)
        finally:
            cost_tracking.deactivate(tracker_token)
        if pack is None:
            raise RuntimeError("PackGenerator returned no pack — PersistStage missing")

        usage_after = await cost_tracking.fetch_openrouter_usage()
        llm_cost_usd: Decimal | None = None
        if usage_before is not None and usage_after is not None:
            llm_cost_usd = round(Decimal(str(max(usage_after - usage_before, 0.0))), 6)

        search_cost_cents = tracker.search_cost_cents
        stage_cost_cents = generator.last_ctx.cost_cents if generator.last_ctx else 0
        llm_cost_cents = int(round(llm_cost_usd * 100)) if llm_cost_usd is not None else 0
        cost_cents = stage_cost_cents + search_cost_cents + llm_cost_cents

        async with session_factory() as session:
            order = await session.get(GenerationOrder, order_uuid)
            job = await session.get(GenerationJob, job_id)
            if order is None or job is None:
                raise LookupError(f"order/job missing after generation: {order_id}")
            order.status = "delivered"
            order.pack_id = pack.id
            order.delivered_at = _now()
            order.llm_cost_usd = llm_cost_usd
            order.search_cost_cents = search_cost_cents
            job.status = "done"
            job.progress = 100
            job.total_cost_cents = cost_cents
            # #145: `total_cost_cents` stays "what the delivered pack cost";
            # the ceiling is checked against the running total for the ORDER,
            # which includes every failed attempt that preceded this one.
            job.cumulative_cost_cents = job.cumulative_cost_cents + cost_cents
            await session.commit()

        done_event_id = await sink.start_step("done")
        await sink.publish(done_event_id, "done", 100)
        logger.info(
            "process_order delivered order_id=%s pack_id=%s cost_cents=%s",
            order_id, pack.id, cost_cents,
        )

    except asyncio.CancelledError:
        # #139 root cause of the silent 2026-08-03 failure: ARQ's job_timeout
        # cancels this coroutine, and CancelledError is a BaseException — the
        # `except Exception` below never ran, so a timed-out job updated no
        # rows and reported nothing. Translate the cancel into a described
        # failure (naming the stage that hung), then let it propagate so ARQ
        # keeps its own timeout/shutdown semantics.
        stage = generator.current_stage if generator else None
        exc = TimeoutError(
            f"process_order cancelled at stage {stage!r} "
            "(ARQ job_timeout or worker shutdown)"
        )
        # warning, not error: the Sentry event for a failed job is the rich
        # capture_exception in _handle_failure (step-log context attached);
        # an error-level log here would double-report via LoggingIntegration.
        logger.warning("process_order cancelled order_id=%s stage=%s", order_id, stage)
        # No OpenRouter round-trip here: this task is being cancelled, so an
        # awaited HTTP call can be interrupted again (and CancelledError is a
        # BaseException the fetch helper does not catch). Stage + search spend
        # is measured locally and still records a non-zero attempt cost.
        attempt_cost = await _attempt_cost_cents(
            tracker, usage_before, generator, fetch_usage=False
        )
        await _handle_failure(
            ctx, order_uuid, order_id, sink, exc, attempt_cost_cents=attempt_cost
        )
        raise
    except Exception as exc:
        logger.warning("process_order failed order_id=%s error=%r", order_id, exc)
        attempt_cost = await _attempt_cost_cents(
            tracker, usage_before, generator, fetch_usage=True
        )
        await _handle_failure(
            ctx, order_uuid, order_id, sink, exc, attempt_cost_cents=attempt_cost
        )
        raise
    finally:
        if heartbeat is not None:
            heartbeat.cancel()


async def _attempt_cost_cents(
    tracker: cost_tracking.OrderCostTracker | None,
    usage_before: float | None,
    generator: PackGenerator | None,
    *,
    fetch_usage: bool,
) -> int:
    """Measured spend of an attempt that did NOT deliver (#145).

    Same three components the success path sums, minus the delivered-pack
    bookkeeping: an attempt that dies in the judge panel has already paid for
    sourcing, generation and verification, and recording nothing for it is
    exactly why the pre-#145 spend hole was invisible. Never raises — a cost
    number we could not measure must not replace the real failure.
    """
    try:
        stage_cost = generator.last_ctx.cost_cents if generator and generator.last_ctx else 0
        search_cost = tracker.search_cost_cents if tracker is not None else 0
        llm_cost = 0
        if fetch_usage and usage_before is not None:
            usage_after = await cost_tracking.fetch_openrouter_usage()
            if usage_after is not None:
                llm_cost = int(round(max(usage_after - usage_before, 0.0) * 100))
        return stage_cost + search_cost + llm_cost
    except Exception:
        logger.warning("failed-attempt cost measurement failed", exc_info=True)
        return 0


def _make_sink_factory(sink: DBProgressSink):
    """Return a sink_factory closure for PackGenerator."""
    def _factory(_order_id: str) -> DBProgressSink:
        return sink
    return _factory


async def _handle_failure(
    ctx: Dict[str, Any],
    order_uuid: uuid.UUID,
    order_id: str,
    sink: DBProgressSink | None,
    exc: Exception,
    attempt_cost_cents: int = 0,
) -> None:
    """Mark job (and order on final retry) failed; publish failure event.

    PackGenerator already opened a ``failed`` step_log entry via the sink
    when the stage raised, so we only own the row updates + the live
    pubsub event for SSE clients.
    """
    from app.worker.worker import WorkerSettings

    job_try: int = ctx.get("job_try", 1)
    max_tries: int = getattr(WorkerSettings, "max_tries", 3)
    session_factory = ctx.get("session_factory") or AsyncSessionLocal

    try:
        async with session_factory() as session:
            order = await session.get(GenerationOrder, order_uuid)
            if order is None:
                return
            job = await session.get(GenerationJob, order.job_id)
            if job is None:
                return
            # #139: sweep-driven recovery re-enqueues under a FRESH ARQ job id,
            # so ctx["job_try"] restarts at 1 on every such attempt. Writing it
            # blindly rewound the sweep's retry_count and the shared budget
            # never exhausted (endless paid retries). The attempt number is
            # whichever counter is further along; the final budgeted attempt is
            # terminal for the ORDER too, not just the job.
            #
            # #145: `+ 1` makes it a real LIFETIME attempt counter — inside the
            # first arq sequence it still tracks `job_try` exactly, but past it
            # (after a manual retry or a sweep recovery) `job_try` restarts and
            # the old `max(retry_count, job_try)` simply stopped counting. An
            # attempt already claimed at enqueue time (sweep/manual retry) is
            # counted twice; the counter is deliberately conservative — it may
            # over-state lifetime attempts, never under-state them.
            effective_try = max(job.retry_count + 1, job_try)
            # Two ways an attempt is the last one: this arq sequence is out of
            # tries (terminal for the order today — it is what makes /retry
            # reachable), or the order has burned its whole lifetime budget.
            is_final = job_try >= max_tries or effective_try >= order_budget.attempt_budget()
            job.status = "failed"
            job.error = repr(exc)
            job.retry_count = effective_try
            # #145: record spend for the attempt that just died — the ceiling
            # is only enforceable because failures pay into this total too.
            job.cumulative_cost_cents = job.cumulative_cost_cents + attempt_cost_cents
            if is_final:
                order.status = "failed"
                order.refund_eligible = True
            current_progress = job.progress
            # PackGenerator already appended a "failed" step_log entry via
            # `sink.start_step("failed", …)` inside its except handler. Capture
            # that entry's event_id while the session is open so the live
            # pubsub publish below uses the real monotonic id — otherwise SSE
            # clients reconnected with `Last-Event-ID > 0` would drop the
            # event via the bridge's `event_id <= last_event_id` dedup check.
            failed_event_id = 0
            if job.step_log:
                failed_event_id = job.step_log[-1].get("event_id", 0)
            step_log_tail = list(job.step_log or [])[-10:]
            await session.commit()

        # #139 — the one Sentry event per failed attempt, carrying the step
        # log so a prod failure names its stage instead of arriving as a bare
        # "stuck past recovery budget". (Callers log at warning level for
        # exactly this reason — see process_order.)
        with sentry_sdk.new_scope() as scope:
            scope.set_context(
                "order",
                {
                    "order_id": order_id,
                    "job_try": job_try,
                    "effective_try": effective_try,
                    "is_final_attempt": is_final,
                    "attempt_cost_cents": attempt_cost_cents,
                },
            )
            scope.set_context("step_log_tail", {"steps": step_log_tail})
            sentry_sdk.capture_exception(exc)

        if sink is not None:
            await sink.publish(
                failed_event_id, "failed", current_progress, info={"error": repr(exc)}
            )
    except Exception as inner:
        logger.error(
            "process_order _handle_failure itself failed order_id=%s inner=%r",
            order_id, inner,
        )
