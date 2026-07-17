"""Tests for `sweep_stuck_orders` — the periodic recovery cron (#103 F4).

Why these matter: before this sweep existed, an order could lodge in
'pending' (Redis blip between commit and enqueue) or 'in_progress' (worker
process hard-killed mid-job) FOREVER — nothing ever re-checked it, the
`/retry` endpoint only accepts 'failed' orders (409 on anything else), and
replaying the same purchase just returns the stuck row as-is. Each test here
drives that exact stuck state through direct DB rows (no live worker) and
asserts the sweep recovers it — either by re-enqueuing or, past the
auto-retry budget, by failing it loudly with `refund_eligible=True`.
"""

from __future__ import annotations

import os
import subprocess
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, AsyncIterator, Dict
from unittest.mock import AsyncMock

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.db.engine import build_engine, normalize_async_url
from app.db.models.job import GenerationJob
from app.db.models.order import GenerationOrder
from app.worker.sweep import (
    IN_PROGRESS_STUCK_TIMEOUT,
    PENDING_STUCK_TIMEOUT,
    sweep_stuck_orders,
)

APP_ROOT = Path(__file__).resolve().parents[2]


def _test_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    return normalize_async_url(url)


@pytest.fixture(scope="module", autouse=True)
def _alembic_head() -> None:
    raw = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not raw:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    env = os.environ.copy()
    env["DATABASE_URL"] = raw
    subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        cwd=APP_ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )


@pytest_asyncio.fixture
async def engine() -> AsyncIterator[AsyncEngine]:
    eng = build_engine(_test_url())
    try:
        yield eng
    finally:
        await eng.dispose()


@pytest_asyncio.fixture
async def session(engine: AsyncEngine) -> AsyncIterator[AsyncSession]:
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with factory() as s:
        yield s


def _session_factory(engine: AsyncEngine):
    return async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


async def _make_stuck_pending(
    session: AsyncSession, *, age: timedelta
) -> tuple[uuid.UUID, uuid.UUID]:
    """Insert an order stuck 'pending' (as if enqueue never happened)."""
    order = GenerationOrder(
        transaction_id=f"sweep-pending-{uuid.uuid4().hex}",
        product_id="pack_10",
        prompt="A prompt long enough for stub generation",
        target_count=10,
        language="en",
        status="pending",
    )
    session.add(order)
    await session.flush()
    job = GenerationJob(order_id=order.id, status="queued")
    session.add(job)
    await session.flush()
    order.job_id = job.id
    # Backdate created_at past the stuck-pending threshold.
    await session.execute(
        text("UPDATE generation_orders SET created_at = :ts WHERE id = :id"),
        {"ts": datetime.now(timezone.utc) - age, "id": order.id},
    )
    await session.commit()
    return order.id, job.id


async def _make_stuck_in_progress(
    session: AsyncSession, *, age: timedelta, retry_count: int = 0
) -> tuple[uuid.UUID, uuid.UUID]:
    """Insert an order stuck 'in_progress' (as if the worker was killed)."""
    order = GenerationOrder(
        transaction_id=f"sweep-inprogress-{uuid.uuid4().hex}",
        product_id="pack_10",
        prompt="A prompt long enough for stub generation",
        target_count=10,
        language="en",
        status="in_progress",
    )
    session.add(order)
    await session.flush()
    job = GenerationJob(order_id=order.id, status="generating", retry_count=retry_count)
    session.add(job)
    await session.flush()
    order.job_id = job.id
    await session.commit()
    # Backdate job.updated_at past the stuck-in-progress threshold.
    await session.execute(
        text("UPDATE generation_jobs SET updated_at = :ts WHERE id = :id"),
        {"ts": datetime.now(timezone.utc) - age, "id": job.id},
    )
    await session.commit()
    return order.id, job.id


async def _cleanup(session: AsyncSession, order_id: uuid.UUID) -> None:
    await session.execute(
        text("DELETE FROM generation_orders WHERE id = :id"), {"id": order_id}
    )
    await session.commit()


class FakeArqPool:
    """Captures `.enqueue_job` calls; can be told to fail once."""

    def __init__(self, *, fail: bool = False) -> None:
        self.calls: list[tuple[str, str]] = []
        self._fail = fail
        self.enqueue_job = AsyncMock(side_effect=self._enqueue)

    async def _enqueue(self, task_name: str, arg: str) -> None:
        if self._fail:
            raise ConnectionError("redis unreachable (simulated)")
        self.calls.append((task_name, arg))


@pytest.mark.asyncio
async def test_sweep_recovers_stuck_pending_order(
    engine: AsyncEngine, session: AsyncSession
) -> None:
    """A 'pending' order past the timeout is re-enqueued and flips to
    'in_progress' — this is the case a Redis blip in create_order (#103 F4a)
    or an earlier failed sweep tick leaves behind."""
    order_id, job_id = await _make_stuck_pending(
        session, age=PENDING_STUCK_TIMEOUT + timedelta(seconds=5)
    )
    pool = FakeArqPool(fail=False)
    ctx: Dict[str, Any] = {
        "redis": pool,
        "session_factory": _session_factory(engine),
    }

    await sweep_stuck_orders(ctx)

    session.expire_all()
    order = await session.get(GenerationOrder, order_id)
    job = await session.get(GenerationJob, job_id)
    assert order.status == "in_progress"
    assert job.status == "queued"
    assert job.retry_count == 1
    assert pool.calls == [("process_order", str(order_id))]

    await _cleanup(session, order_id)


@pytest.mark.asyncio
async def test_sweep_recovers_stuck_in_progress_order(
    engine: AsyncEngine, session: AsyncSession
) -> None:
    """An 'in_progress' order whose job hasn't moved in ages (dead worker) is
    reset to 'queued' and re-enqueued rather than staying stuck forever."""
    order_id, job_id = await _make_stuck_in_progress(
        session, age=IN_PROGRESS_STUCK_TIMEOUT + timedelta(seconds=5)
    )
    pool = FakeArqPool(fail=False)
    ctx: Dict[str, Any] = {
        "redis": pool,
        "session_factory": _session_factory(engine),
    }

    await sweep_stuck_orders(ctx)

    session.expire_all()
    order = await session.get(GenerationOrder, order_id)
    job = await session.get(GenerationJob, job_id)
    assert order.status == "in_progress"
    assert job.status == "queued"
    assert job.retry_count == 1
    assert pool.calls == [("process_order", str(order_id))]

    await _cleanup(session, order_id)


@pytest.mark.asyncio
async def test_sweep_fails_order_past_retry_budget(
    engine: AsyncEngine, session: AsyncSession
) -> None:
    """A stuck order that already exhausted the auto-retry budget
    (retry_count >= max_tries) is marked 'failed' + refund_eligible instead
    of being re-enqueued forever."""
    order_id, job_id = await _make_stuck_in_progress(
        session, age=IN_PROGRESS_STUCK_TIMEOUT + timedelta(seconds=5), retry_count=3
    )
    pool = FakeArqPool(fail=False)
    ctx: Dict[str, Any] = {
        "redis": pool,
        "session_factory": _session_factory(engine),
    }

    await sweep_stuck_orders(ctx)

    session.expire_all()
    order = await session.get(GenerationOrder, order_id)
    job = await session.get(GenerationJob, job_id)
    assert order.status == "failed"
    assert order.refund_eligible is True
    assert job.status == "failed"
    assert pool.calls == []  # never re-enqueued past the budget

    await _cleanup(session, order_id)


@pytest.mark.asyncio
async def test_sweep_leaves_pending_on_enqueue_failure(
    engine: AsyncEngine, session: AsyncSession
) -> None:
    """If the sweep's own re-enqueue attempt fails (Redis still down), the
    order stays 'pending' (not silently 'in_progress') so the NEXT sweep
    tick tries again instead of losing track of it."""
    order_id, job_id = await _make_stuck_pending(
        session, age=PENDING_STUCK_TIMEOUT + timedelta(seconds=5)
    )
    pool = FakeArqPool(fail=True)
    ctx: Dict[str, Any] = {
        "redis": pool,
        "session_factory": _session_factory(engine),
    }

    await sweep_stuck_orders(ctx)

    session.expire_all()
    order = await session.get(GenerationOrder, order_id)
    job = await session.get(GenerationJob, job_id)
    assert order.status == "pending"
    assert job.status == "queued"  # reset, ready for the next tick to retry
    assert job.retry_count == 1

    await _cleanup(session, order_id)


@pytest.mark.asyncio
async def test_sweep_ignores_fresh_orders(
    engine: AsyncEngine, session: AsyncSession
) -> None:
    """A 'pending'/'in_progress' order well within the timeout is untouched —
    the sweep must not race a request that is simply still in flight."""
    pending_id, _ = await _make_stuck_pending(session, age=timedelta(seconds=1))
    inprog_id, _ = await _make_stuck_in_progress(session, age=timedelta(seconds=1))
    pool = FakeArqPool(fail=False)
    ctx: Dict[str, Any] = {
        "redis": pool,
        "session_factory": _session_factory(engine),
    }

    await sweep_stuck_orders(ctx)

    session.expire_all()
    pending_order = await session.get(GenerationOrder, pending_id)
    inprog_order = await session.get(GenerationOrder, inprog_id)
    assert pending_order.status == "pending"
    assert inprog_order.status == "in_progress"
    assert pool.calls == []

    await _cleanup(session, pending_id)
    await _cleanup(session, inprog_id)
