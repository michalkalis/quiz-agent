"""ARQ task: `process_order` stub state machine (issue #33 Task 1.10).

Drives a GenerationOrder through the full job-status pipeline using stub data.
Phase 2 replaces only this file's inner logic; the pubsub/step_log plumbing
established here is the contract that SSE (1.11) and the e2e test (1.12) depend on.
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from datetime import datetime, timezone
from typing import Any, Dict

from quiz_shared.models.question import Question

from app.db.models import (
    GenerationJob,
    GenerationOrder,
    QuestionPack,
    append_step,
    question_to_row,
)
from app.db.session import AsyncSessionLocal

logger = logging.getLogger(__name__)

# Steps in order. Progress is spread evenly: step index × 14 (last step forced to 100).
_STEPS = ["sourcing", "generating", "critiquing", "verifying", "scoring", "persisting", "done"]
_PROGRESS = [14, 28, 42, 56, 70, 84, 100]


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _pub_payload(event_id: int, step: str, progress: int) -> str:
    return json.dumps({"event_id": event_id, "step": step, "progress": progress})


async def process_order(ctx: Dict[str, Any], order_id: str) -> None:
    """Walk a GenerationOrder through sourcing→done, publishing progress on each transition.

    ctx keys consumed:
    - ctx["redis"]      arq.connections.ArqRedis — used for pubsub .publish()
    - ctx["job_try"]    int — current attempt number (1-based, mirrors ARQ internal)
    """
    order_uuid = uuid.UUID(order_id)
    channel = f"order:{order_id}:progress"
    redis = ctx["redis"]
    pack: QuestionPack | None = None
    current_progress = 0

    logger.info("process_order start order_id=%s attempt=%s", order_id, ctx.get("job_try", 1))

    try:
        for step, progress in zip(_STEPS, _PROGRESS):
            current_progress = progress

            async with AsyncSessionLocal() as session:
                order = await session.get(GenerationOrder, order_uuid)
                if order is None:
                    raise LookupError(f"GenerationOrder {order_id} not found")

                job = await session.get(GenerationJob, order.job_id)
                if job is None:
                    raise LookupError(f"GenerationJob for order {order_id} not found")

                started = _now()
                event_id = await append_step(session, job.id, step=step, started_at=started)

                job.status = step
                job.progress = progress

                # Defensive: ensure order is flipped to in_progress on first step.
                if step == "sourcing" and order.status != "in_progress":
                    order.status = "in_progress"

                if step == "persisting":
                    pack = await _persist_pack(session, order)

                if step == "done":
                    if pack is None:
                        raise RuntimeError("pack was not created during persisting step")
                    order.status = "delivered"
                    order.pack_id = pack.id
                    order.delivered_at = _now()
                    job.status = "done"
                    job.progress = 100

                await session.commit()

            await redis.publish(channel, _pub_payload(event_id, step, progress))
            logger.info(
                "process_order step=%s event_id=%s progress=%s order_id=%s",
                step, event_id, progress, order_id,
            )

            if step != "done":
                await asyncio.sleep(1.0)

    except Exception as exc:
        logger.error("process_order failed order_id=%s error=%r", order_id, exc)
        await _handle_failure(ctx, order_uuid, order_id, channel, redis, current_progress, exc)
        raise


async def _persist_pack(session: Any, order: GenerationOrder) -> QuestionPack:
    """Insert QuestionPack + N stub QuestionRows, return the flushed pack."""
    pack = QuestionPack(
        order_id=order.id,
        user_id=order.user_id,
        prompt=order.prompt,
        category=order.category,
        theme=order.theme,
        language=order.language,
        target_count=order.target_count,
        actual_count=order.target_count,
        generated_at=_now(),
    )
    session.add(pack)
    await session.flush()  # populate pack.id

    for i in range(order.target_count):
        # Question.from_dict omits `language` from its constructor call, so we
        # use model_validate directly to preserve the order's language on each stub.
        stub = Question.model_validate({
            "id": str(uuid.uuid4()),
            "type": "single_choice",
            "question": f"Stub question {i}",
            "possible_answers": {"A": "answer", "B": "wrong1", "C": "wrong2", "D": "wrong3"},
            "correct_answer": ["A"],
            "topic": order.category or "stub",
            "category": order.category or "stub",
            "difficulty": "medium",
            "tags": [],
            "language_dependent": False,
            "language": order.language,
        })
        row = question_to_row(stub)
        row.pack_id = pack.id
        session.add(row)

    return pack


async def _handle_failure(
    ctx: Dict[str, Any],
    order_uuid: uuid.UUID,
    order_id: str,
    channel: str,
    redis: Any,
    current_progress: int,
    exc: Exception,
) -> None:
    """Mark job (and order on final retry) failed; publish failure event."""
    from app.worker.worker import WorkerSettings

    job_try: int = ctx.get("job_try", 1)
    max_tries: int = getattr(WorkerSettings, "max_tries", 3)
    is_final = job_try >= max_tries

    try:
        async with AsyncSessionLocal() as session:
            order = await session.get(GenerationOrder, order_uuid)
            if order is None:
                return

            job = await session.get(GenerationJob, order.job_id)
            if job is None:
                return

            event_id = await append_step(
                session, job.id, step="failed", info={"error": repr(exc)}
            )
            job.status = "failed"
            job.error = repr(exc)
            job.retry_count = job_try

            if is_final:
                order.status = "failed"
                order.refund_eligible = True

            await session.commit()

        await redis.publish(
            channel, _pub_payload(event_id, "failed", current_progress)
        )
    except Exception as inner:
        logger.error(
            "process_order _handle_failure itself failed order_id=%s inner=%r",
            order_id, inner,
        )
