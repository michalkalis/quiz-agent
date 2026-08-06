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

Recovery re-enqueues the order (resetting the job to ``queued``) as long as
``app.order_budget`` says the order may spend another attempt — a
sweep-triggered re-enqueue is as much a paid attempt as an ARQ-driven retry, so
it shares the order's spend ceiling and lifetime attempt budget rather than
getting an unbounded one of its own (#145). Past either guard the order is
marked ``failed`` with ``refund_eligible = True``, the same terminal state a
naturally-exhausted ARQ job reaches.

Every re-enqueue carries the deterministic ``attempt_job_id`` so ARQ's own
uniqueness check drops a duplicate enqueue of the same attempt instead of
letting two pipelines bill one purchase twice.
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Dict

from sqlalchemy import select

from app import order_budget
from app.db.models.job import GenerationJob, attempt_job_id
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
        # Staleness is the age of the *queue handoff* (`order.enqueued_at`), not
        # the age of the order: a requeued order (manual /retry, or this sweep's
        # own recovery) has an ancient `created_at`, so measuring that made every
        # requeue look stuck the moment it parked at 'pending' — and the ~ms
        # window before its enqueue was enough for a tick to start a second paid
        # pipeline for the same purchase. Every writer that parks an order at
        # 'pending' bumps `enqueued_at`.
        pending_stmt = select(GenerationOrder.id).where(
            GenerationOrder.status == "pending",
            GenerationOrder.enqueued_at < now - PENDING_STUCK_TIMEOUT,
        )
        pending_ids = (await session.execute(pending_stmt)).scalars().all()

        # Liveness is measured by `job.updated_at` alone: every step append and
        # every requeue bumps it (`GenerationJob.updated_at` onupdate). `queued`
        # deliberately stays inside the predicate — production only ever writes
        # 'queued'/'done'/'failed', so excluding it would match nothing and
        # disable in_progress recovery, which is this sweep's whole purpose.
        # #139: a 'failed' job under a still-'in_progress' order is a parked
        # NON-final failure — ARQ deletes a plain-exception job from its queue
        # (only cancelled jobs re-run), so nothing else will ever retry it and
        # the manual /retry endpoint 409s on a non-'failed' order. Excluding
        # 'failed' here stranded those orders forever; only 'done' is terminal
        # for this predicate (a final failure also flips the ORDER to 'failed',
        # which the order-status filter already excludes).
        in_progress_stmt = (
            select(GenerationOrder.id)
            .join(GenerationJob, GenerationJob.id == GenerationOrder.job_id)
            .where(
                GenerationOrder.status == "in_progress",
                GenerationJob.status != "done",
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
    session_factory = ctx.get("session_factory") or AsyncSessionLocal
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

        # #145 — one shared gate, the same verdict POST /retry and the worker
        # ask for: recovery is as much a paid attempt as any other, so the
        # per-order spend ceiling and the lifetime attempt budget decide here
        # too (they replace this branch's old private `retry_count >= max_tries`
        # rule). Past either one the order goes terminal + refund_eligible —
        # the same state a naturally-exhausted ARQ job reaches.
        verdict = order_budget.evaluate(order, job)
        if not verdict.ok:
            order_budget.mark_exhausted(order, job, verdict)
            job.error = (
                f"sweep: order stuck in {order.status!r} and cut off — {verdict.detail}"
            )
            step_log_tail = list(job.step_log or [])[-10:]
            await session.commit()
            # #139 — this branch is the terminal state a hung-then-killed
            # pipeline lands in (the worker itself never got to raise, so
            # nothing else will ever report it). The 2026-08-03 founder order
            # died exactly here with zero Sentry footprint; a warning-level
            # log is a breadcrumb, not an event, hence the explicit capture.
            order_budget.report_breach(order_id, verdict, step_log_tail)
            return

        job.status = "queued"
        job.progress = 0
        job.error = None
        job.retry_count = job.retry_count + 1
        # #145: a new arq sequence, so a new deterministic job id (the counter
        # the id used to be keyed on no longer resets).
        job.attempt_seq = job.attempt_seq + 1
        order.status = "pending"
        order.enqueued_at = datetime.now(timezone.utc)
        enqueue_id = attempt_job_id(order_id, job)
        await session.commit()

    try:
        await arq_pool.enqueue_job("process_order", str(order_id), _job_id=enqueue_id)
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
