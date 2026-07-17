"""ARQ cron job: recover orders stuck in a non-terminal state (#103 F4).

Two ways an order can lodge forever without this sweep:

- ``pending``: ``create_order``/``retry_order`` commit the order row before
  calling ``enqueue_job``; a Redis blip between those two steps used to leave
  the order ``pending`` with nothing ever going to pick it up (F4a in orders.py
  now catches that at creation time, but a stuck ``pending`` row can still
  exist from before this fix, or from a sweep's own enqueue retry failing).
- ``in_progress``: a hard-killed worker (OOM, deploy, host reboot) leaves the
  order here forever — ARQ's own retry machinery only fires when the job
  function raises, which a killed process never gets to do.

Recovery re-enqueues the order (resetting the job to ``queued``) up to the
same auto-retry budget ``_handle_failure`` uses (``WorkerSettings.max_tries``,
tracked on ``job.retry_count`` — a sweep-triggered re-enqueue is as much an
"automatic attempt" as an ARQ-driven retry, so it shares that budget rather
than getting an unbounded one of its own). Past the cap, the order is marked
``failed`` with ``refund_eligible = True``, the same terminal state a
naturally-exhausted ARQ job reaches.
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Dict

from sqlalchemy import select

from app.db.models.job import GenerationJob
from app.db.models.order import GenerationOrder
from app.db.session import AsyncSessionLocal

logger = logging.getLogger(__name__)

# A 'pending' order should be enqueued within seconds of its commit (F4a's
# fix already catches an enqueue failure inline); this timeout is the safety
# net for anything that slips through — generous enough that no in-flight
# request is ever mistaken for stuck.
PENDING_STUCK_TIMEOUT = timedelta(minutes=3)

# WorkerSettings.job_timeout is 600s (10 min) — ARQ kills a hung job at that
# mark and, if the process is still alive, retries it. A row still
# 'in_progress' well past that mark means the worker process itself died
# (no chance to hit ARQ's own timeout/retry path), so this buffer just needs
# to clear the normal ceiling with room for scheduling jitter.
IN_PROGRESS_STUCK_TIMEOUT = timedelta(minutes=15)


async def sweep_stuck_orders(ctx: Dict[str, Any]) -> None:
    """Find orders stuck in 'pending'/'in_progress' and recover each one."""
    session_factory = ctx.get("session_factory") or AsyncSessionLocal
    now = datetime.now(timezone.utc)

    async with session_factory() as session:
        pending_stmt = select(GenerationOrder.id).where(
            GenerationOrder.status == "pending",
            GenerationOrder.created_at < now - PENDING_STUCK_TIMEOUT,
        )
        pending_ids = (await session.execute(pending_stmt)).scalars().all()

        in_progress_stmt = (
            select(GenerationOrder.id)
            .join(GenerationJob, GenerationJob.id == GenerationOrder.job_id)
            .where(
                GenerationOrder.status == "in_progress",
                GenerationJob.status.notin_(("done", "failed")),
                GenerationJob.updated_at < now - IN_PROGRESS_STUCK_TIMEOUT,
            )
        )
        in_progress_ids = (await session.execute(in_progress_stmt)).scalars().all()

    stuck_ids = list(pending_ids) + list(in_progress_ids)
    if not stuck_ids:
        return

    logger.info("sweep_stuck_orders found %d stuck order(s): %s", len(stuck_ids), stuck_ids)
    for order_id in stuck_ids:
        try:
            await _recover_stuck_order(ctx, order_id)
        except Exception:
            logger.exception("sweep_stuck_orders failed to recover order_id=%s", order_id)


async def _recover_stuck_order(ctx: Dict[str, Any], order_id: uuid.UUID) -> None:
    from app.worker.worker import WorkerSettings

    session_factory = ctx.get("session_factory") or AsyncSessionLocal
    max_tries: int = getattr(WorkerSettings, "max_tries", 3)
    arq_pool = ctx["redis"]

    async with session_factory() as session:
        order_stmt = (
            select(GenerationOrder).where(GenerationOrder.id == order_id).with_for_update()
        )
        order = (await session.execute(order_stmt)).scalars().first()
        if order is None or order.status not in ("pending", "in_progress"):
            # Already recovered by a live worker or a previous sweep tick.
            return

        if order.job_id is None:
            order.status = "failed"
            order.refund_eligible = True
            await session.commit()
            return

        job_stmt = (
            select(GenerationJob).where(GenerationJob.id == order.job_id).with_for_update()
        )
        job = (await session.execute(job_stmt)).scalars().first()
        if job is None:
            order.status = "failed"
            order.refund_eligible = True
            await session.commit()
            return

        if job.retry_count >= max_tries:
            job.status = "failed"
            job.error = (
                f"sweep: order stuck in {order.status!r} past its recovery "
                f"budget (retry_count={job.retry_count}, max={max_tries})"
            )
            order.status = "failed"
            order.refund_eligible = True
            await session.commit()
            logger.warning(
                "sweep_stuck_orders order_id=%s exceeded auto-retry budget; marked failed",
                order_id,
            )
            return

        job.status = "queued"
        job.progress = 0
        job.error = None
        job.retry_count = job.retry_count + 1
        order.status = "pending"
        await session.commit()

    try:
        await arq_pool.enqueue_job("process_order", str(order_id))
    except Exception:
        logger.exception(
            "sweep_stuck_orders re-enqueue failed order_id=%s; left 'pending' "
            "for the next sweep tick",
            order_id,
        )
        return

    async with session_factory() as session:
        order = await session.get(GenerationOrder, order_id)
        if order is not None and order.status == "pending":
            order.status = "in_progress"
            await session.commit()
