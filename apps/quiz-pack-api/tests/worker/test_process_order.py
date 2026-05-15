"""Tests for `process_order` ARQ task (issue #33 Task 1.10).

Drives the task directly as an async function — no running Redis or ARQ daemon
required. A FakeRedis captures .publish() calls so SSE contract is verifiable
without a real broker.

Why these three scenarios matter:
- Happy path: proves the full 7-step state machine delivers a pack with valid
  stub questions and correct step_log shape before Phase 2 wires real generation.
- Failure + final retry: proves refund_eligible is set only on the last attempt,
  not on intermediate ones — otherwise customers would see premature refund flags.
- Non-final retry: proves ARQ's retry backoff window is respected (order stays
  in_progress so the next attempt can continue rather than finding a terminal state).
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, AsyncIterator, Dict, List
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.db.engine import build_engine, normalize_async_url
from app.db.models import (
    GenerationJob,
    GenerationOrder,
    QuestionPack,
    QuestionRow,
    row_to_question,
)

APP_ROOT = Path(__file__).resolve().parents[2]


# ── Test DB plumbing ──────────────────────────────────────────────────────────


def _test_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    return normalize_async_url(url)


@pytest.fixture(scope="module", autouse=True)
def _alembic_head() -> None:
    """Bring the test DB to alembic head once per module."""
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


# ── Fixtures: order + job ─────────────────────────────────────────────────────


async def _create_order_and_job(
    session: AsyncSession, target_count: int = 10
) -> tuple[uuid.UUID, uuid.UUID]:
    """Insert a GenerationOrder + GenerationJob pair, return (order_id, job_id)."""
    order = GenerationOrder(
        transaction_id=f"txn_{uuid.uuid4().hex}",
        product_id="pack_10",
        prompt="A prompt long enough for stub generation",
        target_count=target_count,
        language="en",
        category="general",
        status="in_progress",
    )
    session.add(order)
    await session.flush()

    job = GenerationJob(order_id=order.id, status="queued")
    session.add(job)
    await session.flush()

    order.job_id = job.id
    await session.commit()

    return order.id, job.id


async def _cleanup(session: AsyncSession, order_id: uuid.UUID) -> None:
    """Cascade-delete order (questions, jobs, packs are CASCADE'd)."""
    await session.execute(
        text("DELETE FROM generation_orders WHERE id = :id"), {"id": order_id}
    )
    await session.commit()


# ── Fake Redis ────────────────────────────────────────────────────────────────


class FakeRedis:
    """Captures .publish() calls without a real Redis connection."""

    def __init__(self) -> None:
        self.published: List[tuple[str, str]] = []

    async def publish(self, channel: str, message: str) -> None:
        self.published.append((channel, message))


# ── Helper to patch AsyncSessionLocal inside tasks ───────────────────────────


def _make_session_factory(engine: AsyncEngine):
    """Return an async_sessionmaker bound to the test engine."""
    return async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


# ── Happy path ────────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_happy_path(engine: AsyncEngine, session: AsyncSession) -> None:
    order_id, job_id = await _create_order_and_job(session, target_count=10)

    fake_redis = FakeRedis()
    fake_ctx: Dict[str, Any] = {
        "redis": fake_redis,
        "job_try": 1,
        "job_id": str(uuid.uuid4()),
    }

    test_factory = _make_session_factory(engine)

    with (
        patch("app.worker.tasks.AsyncSessionLocal", test_factory),
        patch("app.worker.tasks.asyncio.sleep", new=AsyncMock(return_value=None)),
    ):
        from app.worker.tasks import process_order
        await process_order(fake_ctx, str(order_id))

    # ── Order assertions ──
    order = await session.get(GenerationOrder, order_id)
    await session.refresh(order)
    assert order.status == "delivered"
    assert order.pack_id is not None
    assert order.delivered_at is not None

    # ── Pack assertions ──
    pack = await session.get(QuestionPack, order.pack_id)
    assert pack is not None
    assert pack.actual_count == 10
    assert pack.target_count == 10

    # ── Question rows ──
    result = await session.execute(
        text("SELECT * FROM questions WHERE pack_id = :pack_id"),
        {"pack_id": pack.id},
    )
    rows = result.fetchall()
    assert len(rows) == 10

    # Each row round-trips through row_to_question without raising.
    for raw_row in rows:
        q_row = await session.get(QuestionRow, raw_row.id)
        assert q_row is not None
        q = row_to_question(q_row)
        assert q.id is not None

    # ── step_log shape ──
    job = await session.get(GenerationJob, job_id)
    await session.refresh(job)
    assert job.status == "done"
    assert job.progress == 100

    step_log = job.step_log
    assert len(step_log) == 7
    expected_steps = ["sourcing", "generating", "critiquing", "verifying", "scoring", "persisting", "done"]
    actual_steps = [e["step"] for e in step_log]
    assert actual_steps == expected_steps

    event_ids = [e["event_id"] for e in step_log]
    assert event_ids == list(range(7))  # monotonic 0..6

    # ── Redis pubsub ──
    channel = f"order:{order_id}:progress"
    published_on_channel = [msg for ch, msg in fake_redis.published if ch == channel]
    assert len(published_on_channel) >= 7

    last_payload = json.loads(published_on_channel[-1])
    assert last_payload["step"] == "done"

    # Cost must be zero — stub pipeline must not call any paid LLM (1.12 guardrail).
    assert job.total_cost_cents == 0

    await _cleanup(session, order_id)


# ── Failure on final retry ────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_failure_final_retry(engine: AsyncEngine, session: AsyncSession) -> None:
    """On job_try == max_tries: order=failed, refund_eligible=True, job.retry_count set."""
    order_id, job_id = await _create_order_and_job(session, target_count=3)

    fake_redis = FakeRedis()
    fake_ctx: Dict[str, Any] = {
        "redis": fake_redis,
        "job_try": 3,  # == max_tries
        "job_id": str(uuid.uuid4()),
    }

    test_factory = _make_session_factory(engine)

    async def _boom(*_args: Any, **_kwargs: Any) -> QuestionPack:
        raise RuntimeError("injected failure in persisting")

    with (
        patch("app.worker.tasks.AsyncSessionLocal", test_factory),
        patch("app.worker.tasks.asyncio.sleep", new=AsyncMock(return_value=None)),
        patch("app.worker.tasks._persist_pack", side_effect=_boom),
    ):
        from app.worker.tasks import process_order
        with pytest.raises(RuntimeError, match="injected failure"):
            await process_order(fake_ctx, str(order_id))

    order = await session.get(GenerationOrder, order_id)
    await session.refresh(order)
    assert order.status == "failed"
    assert order.refund_eligible is True

    job = await session.get(GenerationJob, job_id)
    await session.refresh(job)
    assert job.status == "failed"
    assert job.error is not None
    assert job.retry_count == 3

    channel = f"order:{order_id}:progress"
    failed_events = [
        msg for ch, msg in fake_redis.published
        if ch == channel and json.loads(msg)["step"] == "failed"
    ]
    assert len(failed_events) >= 1

    await _cleanup(session, order_id)


# ── Non-final retry ───────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_failure_non_final_retry(engine: AsyncEngine, session: AsyncSession) -> None:
    """On job_try < max_tries: order stays in_progress, refund_eligible=False."""
    order_id, job_id = await _create_order_and_job(session, target_count=3)

    fake_redis = FakeRedis()
    fake_ctx: Dict[str, Any] = {
        "redis": fake_redis,
        "job_try": 1,  # < max_tries (3)
        "job_id": str(uuid.uuid4()),
    }

    test_factory = _make_session_factory(engine)

    async def _boom(*_args: Any, **_kwargs: Any) -> QuestionPack:
        raise RuntimeError("injected non-final failure")

    with (
        patch("app.worker.tasks.AsyncSessionLocal", test_factory),
        patch("app.worker.tasks.asyncio.sleep", new=AsyncMock(return_value=None)),
        patch("app.worker.tasks._persist_pack", side_effect=_boom),
    ):
        from app.worker.tasks import process_order
        with pytest.raises(RuntimeError, match="injected non-final failure"):
            await process_order(fake_ctx, str(order_id))

    order = await session.get(GenerationOrder, order_id)
    await session.refresh(order)
    # Order must NOT be terminal — ARQ still has retries remaining.
    assert order.status != "failed"
    assert order.refund_eligible is False

    job = await session.get(GenerationJob, job_id)
    await session.refresh(job)
    assert job.status == "failed"
    assert job.retry_count == 1

    await _cleanup(session, order_id)
