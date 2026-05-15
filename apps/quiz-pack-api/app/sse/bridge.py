"""SSE bridge: step_log replay + live Redis pubsub forwarding (issue #33 Task 1.11).

``event_stream`` is the async generator consumed by ``EventSourceResponse`` in
the ``/v1/orders/{order_id}/stream`` route.

Flow:
1. Open a short-lived ``AsyncSession``, read ``job.step_log`` JSONB.
2. Emit all entries with ``event_id > last_event_id`` from the DB (replay).
3. Close the session.
4. If the replay already contained ``done`` or ``failed``, return immediately
   (no pubsub subscribe needed — the job finished before the client connected).
5. Subscribe to Redis pubsub ``order:{order_id}:progress``.
6. Forward live events (filtered ``event_id > last_event_id`` to dedupe the
   narrow race window between steps 2 and 5).
7. Yield a heartbeat SSE comment every 15 s to survive mobile NAT timeouts.
8. On ``done``/``failed`` step: emit final event, then return.
9. ``finally``: always unsubscribe and close the raw Redis connection.
"""

from __future__ import annotations

import json
import logging
import uuid
from typing import AsyncIterator

from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from sse_starlette.sse import ServerSentEvent

from ..db.models.job import GenerationJob
from ..db.models.order import GenerationOrder

logger = logging.getLogger(__name__)

_TERMINAL_STEPS = frozenset({"done", "failed"})


def _make_event(entry: dict) -> ServerSentEvent:
    """Build an SSE event from a step_log entry dict."""
    return ServerSentEvent(
        id=str(entry["event_id"]),
        event=entry["step"],
        data=json.dumps({"step": entry["step"], "progress": entry.get("progress", 0)}),
    )


async def event_stream(
    order_id: str,
    last_event_id: int,
    session_factory: async_sessionmaker[AsyncSession],
    redis_url: str,
) -> AsyncIterator[ServerSentEvent]:
    """Yield SSE events for a generation order.

    Args:
        order_id: String UUID of the order.
        last_event_id: Resume sentinel. ``-1`` means "no Last-Event-ID header
            provided" — emit all events from event_id 0 onward.
        session_factory: SQLAlchemy async session factory (from ``AsyncSessionLocal``).
        redis_url: Redis DSN used to open a dedicated pubsub connection.
    """
    channel = f"order:{order_id}:progress"
    redis_conn: Redis | None = None

    try:
        # ------------------------------------------------------------------
        # Step 1-4: replay step_log from DB
        # ------------------------------------------------------------------
        terminal_in_replay = False

        async with session_factory() as session:
            # Look up the job via the order.
            order_uuid = uuid.UUID(order_id) if isinstance(order_id, str) else order_id
            order = await session.get(GenerationOrder, order_uuid)
            if order is None or order.job_id is None:
                # Nothing to stream yet — yield a single comment and close.
                yield ServerSentEvent(comment="no job found")
                return

            job = await session.get(GenerationJob, order.job_id)
            if job is None:
                yield ServerSentEvent(comment="no job found")
                return

            step_log: list[dict] = job.step_log or []

        replay_entries = [e for e in step_log if e.get("event_id", -1) > last_event_id]
        for entry in replay_entries:
            # step_log entries don't carry progress directly — fill 0 as default;
            # the worker publishes real progress via pubsub (live path).
            yield _make_event(entry)
            if entry.get("step") in _TERMINAL_STEPS:
                terminal_in_replay = True

        if terminal_in_replay:
            return

        # ------------------------------------------------------------------
        # Step 5-9: subscribe to live pubsub events
        # ------------------------------------------------------------------
        redis_conn = Redis.from_url(redis_url, decode_responses=True)
        pubsub = redis_conn.pubsub()
        await pubsub.subscribe(channel)

        try:
            while True:
                # get_message with a 15s timeout is heartbeat-friendly.
                msg = await pubsub.get_message(ignore_subscribe_messages=True, timeout=15.0)

                if msg is None:
                    # Timeout — yield heartbeat comment to keep connection alive.
                    yield ServerSentEvent(comment="heartbeat")
                    continue

                if msg["type"] != "message":
                    continue

                try:
                    payload: dict = json.loads(msg["data"])
                except (json.JSONDecodeError, TypeError):
                    logger.warning("sse: unparseable pubsub message on %s: %r", channel, msg["data"])
                    continue

                event_id: int = payload.get("event_id", -1)
                step: str = payload.get("step", "")
                progress: int = payload.get("progress", 0)

                # Deduplicate the race window between DB replay and subscribe.
                if event_id <= last_event_id:
                    continue

                yield ServerSentEvent(
                    id=str(event_id),
                    event=step,
                    data=json.dumps({"step": step, "progress": progress}),
                )

                if step in _TERMINAL_STEPS:
                    return

        finally:
            await pubsub.unsubscribe(channel)

    finally:
        if redis_conn is not None:
            await redis_conn.aclose()
