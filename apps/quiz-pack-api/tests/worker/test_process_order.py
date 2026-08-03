"""Tests for `process_order` — the ARQ task's worker-layer state machine.

Drives the task directly as an async function (no ARQ daemon, no Redis broker:
a FakeRedis captures the pubsub publishes SSE clients depend on), but with the
SAME collaborators production builds — `app.worker.worker.on_startup` — and
every provider endpoint served by respx. Written that way on purpose: the
previous version of this module hand-stubbed the pipeline and patched a private
worker helper (`_persist_pack`), so #36 task 2.10 renamed the helper out from
under it and all three scenarios sat xfail-ed while the state machine they
cover had no passing test at all. Going through `on_startup` + the ctx
collaborator seam means a wiring change breaks these tests instead of quietly
passing against a stub.

Why these three scenarios matter — each one is a money path:
- Happy path: a paid order must end 'delivered' with a pack whose
  `actual_count` matches the questions actually on disk, a job at 100%, and a
  monotonic step_log covering every stage. Less than that means the customer
  paid and got nothing playable.
- Failure on the FINAL retry: order 'failed' AND refund_eligible=True — the
  only signal that a completed purchase owes a refund.
- Failure on a NON-final retry: refund_eligible must stay False and the order
  must stay 'in_progress', or ARQ's next attempt finds a terminal order and a
  recoverable blip gets refunded/abandoned instead of retried.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any, AsyncIterator, Dict, Iterator, List

import pytest
import pytest_asyncio
import respx
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import get_settings
from app.db.engine import build_engine, normalize_async_url
from app.db.models import (
    GenerationJob,
    GenerationOrder,
    QuestionPack,
    QuestionRow,
    row_to_question,
)
from app.worker.worker import WorkerSettings, on_startup
from tests._isolation import truncate_order_graph

# The canned provider routes live with the integration suite that owns them
# (tests/integration/conftest.py); imported rather than duplicated so the live
# pipeline's mock corpus has exactly one definition.
from tests.integration.conftest import register_e2e_mocks_full

APP_ROOT = Path(__file__).resolve().parents[2]


# ── Test DB plumbing ──────────────────────────────────────────────────────────


def _test_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    return normalize_async_url(url)


@pytest.fixture(scope="module", autouse=True)
def _alembic_head() -> Iterator[None]:
    """Bring the test DB to head, and point the app's DATABASE_URL at it.

    `on_startup` head-checks `get_settings().database_url` before it builds any
    collaborator — a worker must never pull paid orders against a behind-head
    schema. On a dev host that setting names the *dev* DB, which nothing in this
    suite migrates, so without the pin these tests would fail on a database they
    never touch. Restored on teardown; `upgrade head` is a no-op once at head.
    """
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
    with pytest.MonkeyPatch.context() as mp:
        mp.setenv("DATABASE_URL", raw)
        get_settings.cache_clear()
        yield
    get_settings.cache_clear()


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


@pytest_asyncio.fixture(autouse=True)
async def _clean_order_tables(session: AsyncSession) -> None:
    """Start each test from an empty order graph (mirrors tests/api, tests/integration).

    Re-runnability, not tidiness: leftover questions from an earlier run are a
    dedup corpus, and DedupStage drops near-duplicates — so the happy path could
    pass once and then fail forever against the persistent test DB.
    """
    await truncate_order_graph(session)


# ── Fixtures: order + job ─────────────────────────────────────────────────────


async def _create_order_and_job(
    session: AsyncSession, target_count: int = 10
) -> tuple[uuid.UUID, uuid.UUID]:
    """Insert a GenerationOrder + GenerationJob pair, return (order_id, job_id)."""
    order = GenerationOrder(
        transaction_id=f"txn_{uuid.uuid4().hex}",
        product_id="pack_10",
        prompt="Surprising facts about octopus biology",
        target_count=target_count,
        language="en",
        category="science",
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


class _BoomSourcer:
    """FactSourcer double that always raises (Tavily/Wikipedia outage).

    Injected through the ctx collaborator seam production itself uses, so the
    failure-path tests stay valid across stage renames — unlike the private
    `_persist_pack` patch they replace. Which stage raises is irrelevant to what
    they assert: the retry/refund decision must depend on the attempt number
    alone, never on where the pipeline died.
    """

    def __init__(self, message: str) -> None:
        self._message = message

    async def gather_facts(self, *_args: Any, **_kwargs: Any) -> None:
        raise RuntimeError(self._message)


# ── ctx + HTTP mock fixtures ──────────────────────────────────────────────────


@pytest.fixture
def pipeline_http_mocks() -> Iterator[respx.MockRouter]:
    """Serve every provider endpoint the live Phase-2 pipeline touches.

    `assert_all_mocked=True` is the point: PackGenerator really calls
    OpenAI/Tavily/Wikipedia now, so an unmocked route fails the test loudly
    instead of spending money locally or 401-ing in CI.
    """
    with respx.mock(assert_all_called=False, assert_all_mocked=True) as router:
        register_e2e_mocks_full(router)
        yield router


@pytest_asyncio.fixture
async def worker_ctx(
    engine: AsyncEngine, monkeypatch: pytest.MonkeyPatch
) -> AsyncIterator[Dict[str, Any]]:
    """Production ARQ ctx: `on_startup`'s collaborators, bound to the test DB.

    `on_startup` reads `app.db.session.AsyncSessionLocal` for both the stage
    session factory and the pgvector dedup store, so patching that one module
    attribute redirects every write to the test DB.
    """
    import app.db.session as db_session_mod

    test_factory = async_sessionmaker(
        engine, class_=AsyncSession, expire_on_commit=False
    )
    monkeypatch.setattr(db_session_mod, "AsyncSessionLocal", test_factory)

    ctx: Dict[str, Any] = {"redis": FakeRedis(), "job_try": 1}
    await on_startup(ctx)
    # Fail loud rather than write a test's paid-order rows into the dev DB if
    # on_startup ever stops reading the patched module attribute.
    assert ctx["session_factory"] is test_factory
    yield ctx


def _published_on(ctx: Dict[str, Any], order_id: uuid.UUID) -> List[dict]:
    """Decoded pubsub payloads for this order's progress channel."""
    channel = f"order:{order_id}:progress"
    return [
        json.loads(msg) for ch, msg in ctx["redis"].published if ch == channel
    ]


# ── Happy path ────────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_happy_path(
    session: AsyncSession,
    worker_ctx: Dict[str, Any],
    pipeline_http_mocks: respx.MockRouter,
) -> None:
    """A paid order runs the real 7-stage pipeline through to 'delivered'."""
    order_id, job_id = await _create_order_and_job(session, target_count=10)

    from app.worker.tasks import process_order

    await process_order(worker_ctx, str(order_id))

    # process_order commits on its own sessions; drop this session's identity
    # map or it keeps serving the pre-run rows.
    session.expire_all()

    # ── Order ──
    order = await session.get(GenerationOrder, order_id)
    assert order.status == "delivered"
    assert order.pack_id is not None
    assert order.delivered_at is not None

    # ── Pack + questions: what the customer paid for vs. what they got ──
    pack = await session.get(QuestionPack, order.pack_id)
    assert pack is not None
    assert pack.target_count == 10
    rows = (
        (
            await session.execute(
                select(QuestionRow).where(QuestionRow.pack_id == pack.id)
            )
        )
        .scalars()
        .all()
    )
    assert rows, "order was delivered with zero questions persisted"
    # `actual_count` is what the client shows for a short pack (#103 F5); it
    # must never overstate the rows on disk.
    assert pack.actual_count == len(rows)
    for row in rows:
        # The play path reads these rows through row_to_question; a row it can't
        # parse is a delivered-but-unplayable pack.
        assert row_to_question(row).id is not None
        assert row.source_url, "question persisted without source attribution (F8)"

    # ── Job + step_log ──
    job = await session.get(GenerationJob, job_id)
    assert job.status == "done"
    assert job.progress == 100

    expected_steps = [
        "sourcing",
        "generating",
        "dedup",
        # #135 D10 — round-trip check sits between dedup and verification.
        "answerability",
        "verifying",
        "scoring",
        "topup",
        "persisting",
        "done",
    ]
    assert [e["step"] for e in job.step_log] == expected_steps
    # event_ids must be monotonic 0..n: the SSE bridge replays by
    # `event_id > Last-Event-ID`, so a gap or repeat silently drops progress
    # events for any client that reconnects.
    assert [e["event_id"] for e in job.step_log] == list(range(len(expected_steps)))

    # Real spend, bounded: 0 would mean no stage did paid work, and the Phase-2
    # sanity ceiling catches a runaway pack (Phase 3 tightens per tier).
    assert 0 < job.total_cost_cents < 100

    # ── Redis pubsub (SSE contract) ──
    payloads = _published_on(worker_ctx, order_id)
    assert len(payloads) >= len(expected_steps)
    assert payloads[-1]["step"] == "done"

    await _cleanup(session, order_id)


# ── Failure on final retry ────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_failure_final_retry(
    session: AsyncSession,
    worker_ctx: Dict[str, Any],
    pipeline_http_mocks: respx.MockRouter,
) -> None:
    """On the last attempt: order=failed, refund_eligible=True, retry_count set."""
    order_id, job_id = await _create_order_and_job(session, target_count=3)

    worker_ctx["job_try"] = WorkerSettings.max_tries  # the final attempt
    worker_ctx["fact_sourcer"] = _BoomSourcer("injected sourcing outage")

    from app.worker.tasks import process_order

    with pytest.raises(RuntimeError, match="injected sourcing outage"):
        await process_order(worker_ctx, str(order_id))

    session.expire_all()
    order = await session.get(GenerationOrder, order_id)
    assert order.status == "failed"
    # The only machine-readable "this purchase owes a refund" signal.
    assert order.refund_eligible is True

    job = await session.get(GenerationJob, job_id)
    assert job.status == "failed"
    assert job.error is not None, "terminal failure with no error recorded"
    assert job.retry_count == WorkerSettings.max_tries

    # SSE clients must see the failure, not just stop receiving progress.
    failed_events = [p for p in _published_on(worker_ctx, order_id) if p["step"] == "failed"]
    assert len(failed_events) >= 1

    await _cleanup(session, order_id)


# ── Non-final retry ───────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_failure_non_final_retry(
    session: AsyncSession,
    worker_ctx: Dict[str, Any],
    pipeline_http_mocks: respx.MockRouter,
) -> None:
    """Before the last attempt: order stays in_progress, refund_eligible=False."""
    assert WorkerSettings.max_tries > 1, "premise: there is a non-final attempt"
    order_id, job_id = await _create_order_and_job(session, target_count=3)

    worker_ctx["job_try"] = 1  # < max_tries
    worker_ctx["fact_sourcer"] = _BoomSourcer("injected non-final failure")

    from app.worker.tasks import process_order

    with pytest.raises(RuntimeError, match="injected non-final failure"):
        await process_order(worker_ctx, str(order_id))

    session.expire_all()
    order = await session.get(GenerationOrder, order_id)
    # Not terminal — ARQ still has retries left, and a 'failed' order here would
    # both refund a recoverable blip and make POST /retry the only way forward.
    assert order.status == "in_progress"
    assert order.refund_eligible is False

    job = await session.get(GenerationJob, job_id)
    assert job.status == "failed"
    assert job.retry_count == 1

    await _cleanup(session, order_id)
