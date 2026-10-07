"""Writes analytics events to Postgres without ever slowing or failing a request.

Server emits are fire-and-forget (``emit``): the write runs as a background
task and any failure is logged, never raised — analytics must not cost the
player a question. Client batches are awaited (``record_client_batch``) so the
ingest route can answer honestly. With no database configured (plain local
dev) every call is a no-op.
"""

from __future__ import annotations

import asyncio
import logging
from contextvars import ContextVar
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from ..db.base import utcnow
from ..db.models import AnalyticsEvent
from .taxonomy import CLIENT_EVENTS, SERVER_EVENTS, clean_properties

logger = logging.getLogger(__name__)

# Set per request from the app's ``X-App-Version`` header (main.py middleware)
# so server-side events carry the client build without threading it through
# every call site.
app_version_var: ContextVar[str | None] = ContextVar("app_version", default=None)


class AppVersionMiddleware:
    """Pure ASGI (no response buffering, safe for audio streaming): copies the
    ``X-App-Version`` request header into ``app_version_var`` for the request."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        version = None
        for key, value in scope.get("headers", []):
            if key == b"x-app-version":
                version = value.decode("latin-1")[:32] or None
                break
        token = app_version_var.set(version)
        try:
            await self.app(scope, receive, send)
        finally:
            app_version_var.reset(token)


# asyncio keeps only weak refs to tasks; hold them until they finish.
_pending: set[asyncio.Task] = set()


@dataclass(frozen=True)
class ClientEvent:
    name: str
    occurred_at: datetime | None
    session_id: str | None
    properties: dict[str, Any]


class AnalyticsRecorder:
    def __init__(self, sessionmaker=None):
        self._sessionmaker = sessionmaker

    def emit(
        self,
        name: str,
        *,
        subject_id: str | None = None,
        session_id: str | None = None,
        properties: dict[str, Any] | None = None,
    ) -> None:
        """Record one server-side event in the background (never raises)."""
        allowed = SERVER_EVENTS.get(name)
        if allowed is None:
            logger.error("analytics: unknown server event %r dropped", name)
            return
        if self._sessionmaker is None:
            return
        row = AnalyticsEvent(
            name=name,
            occurred_at=utcnow(),
            subject_id=subject_id,
            session_id=session_id,
            source="server",
            app_version=app_version_var.get(),
            properties=clean_properties(allowed, properties),
        )
        try:
            task = asyncio.get_running_loop().create_task(self._write_quietly([row]))
        except RuntimeError:  # no running loop (sync caller) — skip, never raise
            logger.warning("analytics: no event loop, %s dropped", name)
            return
        _pending.add(task)
        task.add_done_callback(_pending.discard)

    async def record_client_batch(
        self,
        events: list[ClientEvent],
        *,
        subject_id: str | None,
        app_version: str | None,
    ) -> tuple[int, int]:
        """Store the allowlisted events of one app batch → (accepted, dropped)."""
        rows = []
        for event in events:
            allowed = CLIENT_EVENTS.get(event.name)
            if allowed is None:
                continue
            now = utcnow()
            occurred = event.occurred_at or now
            # An offset-less client timestamp is read as UTC (timestamptz column;
            # comparing it to the aware ``now`` would otherwise raise).
            if occurred.tzinfo is None:
                occurred = occurred.replace(tzinfo=now.tzinfo)
            # A device clock far in the future would poison day buckets.
            occurred = min(occurred, now)
            rows.append(
                AnalyticsEvent(
                    name=event.name,
                    occurred_at=occurred,
                    received_at=now,
                    subject_id=subject_id,
                    session_id=event.session_id,
                    source="ios",
                    app_version=app_version,
                    properties=clean_properties(allowed, event.properties),
                )
            )
        dropped = len(events) - len(rows)
        if rows and self._sessionmaker is not None:
            await self._write(rows)
        return len(rows), dropped

    async def _write(self, rows: list[AnalyticsEvent]) -> None:
        async with self._sessionmaker() as session:
            session.add_all(rows)
            await session.commit()

    async def _write_quietly(self, rows: list[AnalyticsEvent]) -> None:
        try:
            await self._write(rows)
        except Exception as e:  # analytics must never break the caller
            logger.warning("analytics: write of %d event(s) failed: %s", len(rows), e)


async def drain_pending() -> None:
    """Wait for in-flight background writes (tests, graceful shutdown)."""
    if _pending:
        await asyncio.gather(*list(_pending), return_exceptions=True)
