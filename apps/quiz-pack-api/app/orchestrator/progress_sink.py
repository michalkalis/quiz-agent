"""ProgressSink Protocol — how stages report start/finish/interim progress."""

from __future__ import annotations

from typing import Any, Protocol


class ProgressSink(Protocol):
    """Receives per-stage lifecycle events from PackGenerator.

    Concrete implementation `DBProgressSink` (task 2.2) writes to the
    Postgres `step_log` table and publishes to Redis. Tests substitute
    an in-memory recording sink.
    """

    async def start_step(self, step: str) -> int:
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
