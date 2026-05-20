"""Integration tests for PersistStage (issue #36 task 2.9).

PersistStage is the only orchestrator stage that touches Postgres directly,
so its tests need a live test DB (the rest of the stage tests use in-memory
doubles). They mirror the setup used by `tests/db/test_core_entities.py`:
alembic upgrade-to-head once per module, then per-test sessions.

Why these scenarios:

- `test_persists_pack_and_questions`: the headline contract — given a
  populated `ctx`, the stage must insert one `QuestionPack` row and one
  `QuestionRow` per `ctx.questions` entry, with the `pack_id` foreign key
  wired up. If this regresses, generated packs would simply not land in
  the database despite the pipeline reporting success.
- `test_rerun_with_same_question_ids_is_noop`: idempotency under retry.
  A re-enqueued ARQ job (issue #36 task 2.18) must be safe to re-run; if
  the stage threw on duplicate question ids we'd block legitimate retries
  with `UniqueViolation` instead of recovering cleanly. The `ON CONFLICT
  (id) DO NOTHING` clause is what makes that safe.
- `test_pack_actual_count_matches_kept_questions`: dedup (task 2.8) can
  drop questions before persist runs, so `actual_count` must reflect the
  *kept* count, not the order's original `target_count`. A reviewer
  reading `actual_count` later relies on this to spot under-filled packs.
- `test_embedding_model_defaults_filled_when_embedding_present`: callers
  may produce a `Question.embedding` without setting the model/dim fields
  (the question generator does this today). Persist must normalise those
  to the canonical defaults so queries against `embedding_model` still
  filter correctly.
"""

from __future__ import annotations

import os
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, AsyncIterator

import pytest
import pytest_asyncio
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.db.engine import build_engine, normalize_async_url
from app.db.models import (
    EMBEDDING_DIM,
    GenerationOrder,
    QuestionPack,
    QuestionRow,
)
from app.orchestrator import OrderContext
from app.orchestrator.stages.persist import DEFAULT_EMBEDDING_MODEL, PersistStage
from quiz_shared.models.question import Question

APP_ROOT = Path(__file__).resolve().parents[3]


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
async def session_factory(
    engine: AsyncEngine,
) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


@pytest_asyncio.fixture
async def session(
    session_factory: async_sessionmaker[AsyncSession],
) -> AsyncIterator[AsyncSession]:
    async with session_factory() as s:
        yield s


class _RecordingSink:
    """ProgressSink double — PersistStage does not call it, but the protocol requires it."""

    def __init__(self) -> None:
        self.events: list[tuple[str, str, Any]] = []
        self._next_id = 0

    async def start_step(self, step: str, info: Any = None) -> int:
        eid = self._next_id
        self._next_id += 1
        self.events.append(("start", step, info))
        return eid

    async def finish_step(self, step: str, event_id: int, info: Any = None) -> None:
        self.events.append(("finish", step, info))

    async def publish(
        self, event_id: int, step: str, progress: int, info: Any = None
    ) -> None:
        self.events.append(("publish", step, info))


async def _make_order(session: AsyncSession, *, target_count: int = 3) -> GenerationOrder:
    order = GenerationOrder(
        transaction_id=f"persist-tx-{uuid.uuid4().hex}",
        product_id="pack_10",
        prompt="famous capitals of europe",
        category="geography",
        theme="capitals",
        target_count=target_count,
        language="en",
        status="in_progress",
    )
    session.add(order)
    await session.commit()
    return order


def _stub_question(idx: int = 0, **overrides: Any) -> Question:
    base: dict[str, Any] = dict(
        id=str(uuid.uuid4()),
        question=f"Stub question {idx}",
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="geography",
        difficulty="easy",
        language="en",
        source="generated",
        source_url=f"https://example.com/fact/{idx}",
        source_excerpt="A short excerpt.",
        review_status="approved",
    )
    base.update(overrides)
    return Question(**base)


def _make_ctx(order: GenerationOrder, questions: list[Question]) -> OrderContext:
    ctx = OrderContext(
        order_id=order.id,
        prompt=order.prompt,
        language=order.language,
        target_count=order.target_count,
        category=order.category,
        theme=order.theme,
    )
    ctx.questions = list(questions)
    return ctx


async def _cleanup_order(session: AsyncSession, order_id: uuid.UUID) -> None:
    # `questions.pack_id` has ON DELETE SET NULL, so questions linger after the
    # pack cascades away. Delete them explicitly so the test is hermetic.
    await session.execute(
        text(
            "DELETE FROM questions WHERE pack_id IN "
            "(SELECT id FROM question_packs WHERE order_id = :oid)"
        ),
        {"oid": order_id},
    )
    await session.execute(
        text("DELETE FROM generation_orders WHERE id = :oid"),
        {"oid": order_id},
    )
    await session.commit()


# ── Tests ────────────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_persists_pack_and_questions(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    order = await _make_order(session, target_count=3)
    questions = [_stub_question(i) for i in range(3)]
    ctx = _make_ctx(order, questions)

    stage = PersistStage(session_factory)
    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert ctx.pack_id is not None
    assert result.info["persisted"] == 3
    assert result.info["pack_id"] == str(ctx.pack_id)
    assert isinstance(result.info["pack"], QuestionPack)

    pack = await session.get(QuestionPack, ctx.pack_id)
    assert pack is not None
    assert pack.order_id == order.id
    assert pack.actual_count == 3
    assert pack.generated_at is not None

    stmt = select(func.count()).where(QuestionRow.pack_id == ctx.pack_id)
    count = (await session.execute(stmt)).scalar_one()
    assert count == 3

    # Each persisted row points back to the new pack and keeps its source_url.
    rows_stmt = select(QuestionRow).where(QuestionRow.pack_id == ctx.pack_id)
    rows = (await session.execute(rows_stmt)).scalars().all()
    assert {str(r.pack_id) for r in rows} == {str(ctx.pack_id)}
    assert all(r.source_url is not None for r in rows)

    await _cleanup_order(session, order.id)


@pytest.mark.asyncio
async def test_rerun_with_same_question_ids_is_noop(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    order = await _make_order(session, target_count=2)
    questions = [_stub_question(i) for i in range(2)]
    stage = PersistStage(session_factory)

    ctx1 = _make_ctx(order, questions)
    first = await stage.run(ctx1, sink=_RecordingSink())  # type: ignore[arg-type]
    assert first.info["persisted"] == 2

    ctx2 = _make_ctx(order, questions)
    second = await stage.run(ctx2, sink=_RecordingSink())  # type: ignore[arg-type]
    # ON CONFLICT (id) DO NOTHING — the second insert reports 0 rows written.
    assert second.info["persisted"] == 0

    # The question table still has exactly two rows for these ids; no duplicates.
    qids = [uuid.UUID(q.id) for q in questions]
    stmt = select(func.count()).where(QuestionRow.id.in_(qids))
    count = (await session.execute(stmt)).scalar_one()
    assert count == 2

    await _cleanup_order(session, order.id)


@pytest.mark.asyncio
async def test_pack_actual_count_matches_kept_questions(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """Order asked for 10 but dedup left only 4 in ctx — actual_count must be 4."""
    order = await _make_order(session, target_count=10)
    questions = [_stub_question(i) for i in range(4)]
    ctx = _make_ctx(order, questions)

    stage = PersistStage(session_factory)
    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    pack = await session.get(QuestionPack, ctx.pack_id)
    assert pack is not None
    assert pack.target_count == 10
    assert pack.actual_count == 4

    await _cleanup_order(session, order.id)


@pytest.mark.asyncio
async def test_embedding_model_defaults_filled_when_embedding_present(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    order = await _make_order(session, target_count=1)
    q = _stub_question(0, embedding=[0.1] * EMBEDDING_DIM)
    # Sanity: caller did NOT set embedding_model / embedding_dim
    assert q.embedding_model is None
    assert q.embedding_dim is None

    ctx = _make_ctx(order, [q])
    stage = PersistStage(session_factory)
    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    row = await session.get(QuestionRow, uuid.UUID(q.id))
    assert row is not None
    assert row.embedding is not None
    assert row.embedding_model == DEFAULT_EMBEDDING_MODEL
    assert row.embedding_dim == EMBEDDING_DIM

    await _cleanup_order(session, order.id)
