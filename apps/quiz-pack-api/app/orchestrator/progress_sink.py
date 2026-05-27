"""ProgressSink Protocol + DBProgressSink concrete implementation.

``DBProgressSink`` writes step_log entries to Postgres and pubsub events to
Redis. The append_step + redis.publish calls that lived inline in the
Phase 1 worker stub now flow through this class so Phase 2 stages share
the seam.
"""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from typing import Any, Protocol

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.db.models.job import append_step


class ProgressSink(Protocol):
    """Receives per-stage lifecycle events from PackGenerator.

    Concrete implementation `DBProgressSink` writes to the Postgres
    `step_log` table and publishes to Redis. Tests substitute an
    in-memory recording sink.
    """

    async def start_step(
        self, step: str, info: dict[str, Any] | None = None
    ) -> int:
        """Open a new step_log row, return its event_id."""
        ...

    async def finish_step(
        self, step: str, event_id: int, info: dict[str, Any] | None = None
    ) -> None:
        """Close the step_log row opened by `start_step`."""
        ...

    async def publish(
        self,
        event_id: int,
        step: str,
        progress: int,
        info: dict[str, Any] | None = None,
    ) -> None:
        """Push a progress event to Redis pubsub for SSE consumers."""
        ...


class DBProgressSink:
    """ProgressSink that writes step_log rows to Postgres + publishes to Redis.

    One instance per ARQ job. Each ``start_step`` opens a short-lived
    session via ``session_factory``, appends a step_log entry to
    ``generation_jobs.step_log``, commits, and returns the new
    ``event_id``. ``publish`` pushes a JSON payload onto the Redis
    pubsub channel — the format matches the Phase 1 stub verbatim so
    SSE clients (#33 task 1.11) keep working unchanged.
    """

    def __init__(
        self,
        session_factory: async_sessionmaker[AsyncSession],
        redis: Any,
        channel: str,
        job_id: uuid.UUID,
    ) -> None:
        self._session_factory = session_factory
        self._redis = redis
        self._channel = channel
        self._job_id = job_id

    async def start_step(
        self, step: str, info: dict[str, Any] | None = None
    ) -> int:
        async with self._session_factory() as session:
            event_id = await append_step(
                session,
                self._job_id,
                step=step,
                info=info,
                started_at=datetime.now(timezone.utc),
            )
            await session.commit()
        return event_id

    async def finish_step(
        self, step: str, event_id: int, info: dict[str, Any] | None = None
    ) -> None:
        # Phase 1 contract: one `step_log` entry per step (the one `start_step`
        # appended). The live "finished" signal travels via `publish()` to
        # Redis pubsub — SSE clients get it from there. Writing a second
        # `step_log` entry here would double every SSE replay event.
        return None

    async def publish(
        self,
        event_id: int,
        step: str,
        progress: int,
        info: dict[str, Any] | None = None,
    ) -> None:
        payload: dict[str, Any] = {
            "event_id": event_id,
            "step": step,
            "progress": progress,
        }
        await self._redis.publish(self._channel, json.dumps(payload))
