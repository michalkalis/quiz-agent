"""`generation_jobs` ORM table + atomic `append_step` helper (issue #33 Task 1.5).

`step_log` is a JSONB array of `{event_id, step, started_at, finished_at, info}`.
Naïve read-modify-write would lose events under concurrent worker steps; the
helper here uses a single UPDATE so the new entry's `event_id` is computed
inside the same statement that appends it (R9 in the issue risk register).
"""

from __future__ import annotations

import json
import uuid
from datetime import datetime
from typing import Any, Dict, Optional

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Integer,
    SmallInteger,
    String,
    Text,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import Mapped, mapped_column

from ..base import Base, UUIDPrimaryKeyMixin

JOB_STATUSES = (
    "queued",
    "sourcing",
    "generating",
    "critiquing",
    "verifying",
    "scoring",
    "persisting",
    "done",
    "failed",
)


class GenerationJob(Base, UUIDPrimaryKeyMixin):
    __tablename__ = "generation_jobs"

    order_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True),
        ForeignKey("generation_orders.id", ondelete="CASCADE"),
        nullable=False,
    )
    status: Mapped[str] = mapped_column(
        String(32), nullable=False, default="queued", server_default="queued"
    )
    progress: Mapped[int] = mapped_column(
        SmallInteger, nullable=False, default=0, server_default=text("0")
    )
    step_log: Mapped[list] = mapped_column(
        JSONB, nullable=False, default=list, server_default=text("'[]'::jsonb")
    )
    total_cost_cents: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default=text("0")
    )
    # #145: spend for the DELIVERED pack only lives in `total_cost_cents`
    # (assigned on the success path). This one accumulates every attempt,
    # success or failure — it is the number the per-order spend ceiling is
    # checked against, and the reason the pre-#145 money hole was invisible in
    # the data (a failed attempt recorded nothing at all).
    cumulative_cost_cents: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default=text("0")
    )
    # #145: lifetime attempt counter for the ORDER — never reset. `/retry` used
    # to zero it (so the ARQ job id stayed unique across manual retries), which
    # handed every manual retry a fresh 3-attempt auto budget: ~12 paid frontier
    # runs for one purchase. Uniqueness now comes from `attempt_seq`, so this
    # counter is free to mean what its name implies.
    retry_count: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default=text("0")
    )
    # #145: monotonic ARQ enqueue sequence — bumped by every actor that starts a
    # NEW arq sequence for this job (manual retry, sweep recovery). Its only job
    # is keeping `attempt_job_id` unique; nothing gates on it.
    attempt_seq: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default=text("0")
    )
    # #103 F1: the manual-retry budget the `/retry` endpoint gates on.
    # Independent of `retry_count` (set to the ARQ `job_try` on every
    # automatic failure, so a terminal 'failed' order always has
    # `retry_count == max_tries` — gating the manual endpoint on that field
    # made it un-retryable for every real failure).
    manual_retry_count: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default=text("0")
    )
    error: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )
    # `onupdate` is load-bearing for the stuck-order sweep, which measures job
    # liveness by `updated_at`. Its only writer used to be `append_step`'s
    # explicit `now()`, so a requeue (manual /retry or a sweep recovery) left the
    # timestamp at the last completed step — hours stale — and the very next
    # sweep tick classified the freshly queued job as stuck and started a second
    # paid pipeline for the same order. Client-side default: no DDL, no migration.
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=text("now()"),
        onupdate=func.now(),
    )

    __table_args__ = (
        CheckConstraint(
            "status IN ('queued','sourcing','generating','critiquing','verifying',"
            "'scoring','persisting','done','failed')",
            name="ck_jobs_status",
        ),
        CheckConstraint(
            "progress >= 0 AND progress <= 100",
            name="ck_jobs_progress",
        ),
    )


def attempt_job_id(order_id: uuid.UUID, job: GenerationJob) -> str:
    """Deterministic arq ``_job_id`` for one processing attempt of ``order_id``.

    With no explicit id arq assigns a random ``uuid4``, so nothing stopped a
    duplicate enqueue of the *same* attempt — a requeue racing the stuck-order
    sweep — from running two paid pipelines for one purchase: double LLM +
    search spend, two ``QuestionPack`` rows, one of them orphaned.

    #145: the key is ``attempt_seq``, a field whose only purpose is this id.
    It used to be ``retry_count``+``manual_retry_count``, which is why ``/retry``
    had to zero ``retry_count`` to stay unique — and zeroing it handed every
    manual retry a fresh auto-retry budget (up to ~12 paid runs per purchase).
    """
    return f"process_order:{order_id}:{job.attempt_seq}"


# Single-statement append: the new entry's `event_id` is `jsonb_array_length(step_log)`
# evaluated against the OLD row in the SET clause (Postgres evaluates RHS references
# pre-update); the RETURNING clause reads the NEW length minus one — both yield the
# same monotonic index. Concurrent UPDATEs serialise on the row lock, so no events
# can collide on `event_id`.
_APPEND_STEP_SQL = text(
    """
    UPDATE generation_jobs
    SET step_log = step_log || jsonb_build_array(
            jsonb_set(
                CAST(:payload AS jsonb),
                '{event_id}',
                to_jsonb(jsonb_array_length(step_log))
            )
        ),
        updated_at = now()
    WHERE id = :job_id
    RETURNING (jsonb_array_length(step_log) - 1) AS event_id
    """
)


async def append_step(
    session: AsyncSession,
    job_id: uuid.UUID,
    step: str,
    info: Optional[Dict[str, Any]] = None,
    started_at: Optional[datetime] = None,
    finished_at: Optional[datetime] = None,
) -> int:
    """Atomically append a step entry to `generation_jobs.step_log`.

    Returns the new entry's `event_id` (monotonically increasing per job).
    """
    payload: Dict[str, Any] = {"step": step, "info": info or {}}
    if started_at is not None:
        payload["started_at"] = _to_iso(started_at)
    if finished_at is not None:
        payload["finished_at"] = _to_iso(finished_at)

    result = await session.execute(
        _APPEND_STEP_SQL,
        {"payload": json.dumps(payload), "job_id": job_id},
    )
    row = result.first()
    if row is None:
        raise LookupError(f"generation_jobs row {job_id} not found")
    return int(row.event_id)


def _to_iso(dt: datetime) -> str:
    """Normalise to ISO-8601 with a `Z`/offset; naïve datetimes treated as UTC."""
    if dt.tzinfo is None:
        from datetime import timezone

        dt = dt.replace(tzinfo=timezone.utc)
    return dt.isoformat()
