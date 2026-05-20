"""ARQ task: `process_order` — drives an order through `PackGenerator`.

Issue #36 task 2.10 replaced the Phase-1 stub with a real orchestrator
walk. The stages (sourcing → generating → verifying → scoring → dedup →
persisting) live in ``app/orchestrator/stages``; this module wires them
to the ARQ ``ctx`` collaborators built in ``app.worker.worker.on_startup``
and handles the worker-layer concerns the orchestrator deliberately
omits: order/job row updates, cost-cents accounting, retry semantics,
and the final ``done`` event SSE clients expect.
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, Sequence

from app.db.models import GenerationJob, GenerationOrder
from app.db.session import AsyncSessionLocal
from app.orchestrator import PackGenerator
from app.orchestrator.pack_generator import Stage
from app.orchestrator.progress_sink import DBProgressSink
from app.orchestrator.stages import (
    DedupStage,
    GenerationStage,
    PersistStage,
    ScoringStage,
    SourcingStage,
    VerificationStage,
)

logger = logging.getLogger(__name__)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _build_stages(ctx: Dict[str, Any]) -> list[Stage]:
    """Compose the six Phase-2 stages from collaborators on ARQ ctx."""
    session_factory = ctx.get("session_factory") or AsyncSessionLocal
    return [
        SourcingStage(ctx["fact_sourcer"]),
        GenerationStage(ctx["generator"]),
        VerificationStage(ctx["fact_verifier"]),
        ScoringStage(ctx["scorer"]),
        DedupStage(ctx["question_store"], ctx.get("gold_standard_path")),
        PersistStage(session_factory),
    ]


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
            if order.status != "in_progress":
                order.status = "in_progress"
                await session.commit()

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

        pack = await generator.run(order_snapshot)
        if pack is None:
            raise RuntimeError("PackGenerator returned no pack — PersistStage missing")

        cost_cents = generator.last_ctx.cost_cents if generator.last_ctx else 0

        async with session_factory() as session:
            order = await session.get(GenerationOrder, order_uuid)
            job = await session.get(GenerationJob, job_id)
            if order is None or job is None:
                raise LookupError(f"order/job missing after generation: {order_id}")
            order.status = "delivered"
            order.pack_id = pack.id
            order.delivered_at = _now()
            job.status = "done"
            job.progress = 100
            job.total_cost_cents = cost_cents
            await session.commit()

        done_event_id = await sink.start_step("done")
        await sink.publish(done_event_id, "done", 100)
        logger.info(
            "process_order delivered order_id=%s pack_id=%s cost_cents=%s",
            order_id, pack.id, cost_cents,
        )

    except Exception as exc:
        logger.error("process_order failed order_id=%s error=%r", order_id, exc)
        await _handle_failure(ctx, order_uuid, order_id, sink, exc)
        raise


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
) -> None:
    """Mark job (and order on final retry) failed; publish failure event.

    PackGenerator already opened a ``failed`` step_log entry via the sink
    when the stage raised, so we only own the row updates + the live
    pubsub event for SSE clients.
    """
    from app.worker.worker import WorkerSettings

    job_try: int = ctx.get("job_try", 1)
    max_tries: int = getattr(WorkerSettings, "max_tries", 3)
    is_final = job_try >= max_tries
    session_factory = ctx.get("session_factory") or AsyncSessionLocal

    try:
        async with session_factory() as session:
            order = await session.get(GenerationOrder, order_uuid)
            if order is None:
                return
            job = await session.get(GenerationJob, order.job_id)
            if job is None:
                return
            job.status = "failed"
            job.error = repr(exc)
            job.retry_count = job_try
            if is_final:
                order.status = "failed"
                order.refund_eligible = True
            current_progress = job.progress
            await session.commit()

        if sink is not None:
            await sink.publish(0, "failed", current_progress, info={"error": repr(exc)})
    except Exception as inner:
        logger.error(
            "process_order _handle_failure itself failed order_id=%s inner=%r",
            order_id, inner,
        )
