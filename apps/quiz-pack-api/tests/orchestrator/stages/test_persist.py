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
from app.orchestrator.stages.persist import (
    DEFAULT_EMBEDDING_MODEL,
    PersistStage,
    fail_pack_in_session,
)
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
    # #182: the legacy single-shot path must still land a pack a live-quiz
    # read treats as immediately playable, not stuck in the new 'generating'
    # state that batch persistence introduced for the incremental path.
    assert pack.generation_status == "complete"

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


@pytest.mark.asyncio
async def test_embedding_qa_lands_with_model_default_and_stays_null_otherwise(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """#170 D2/D10: a question carrying `embedding_qa` must land with the
    vector AND the model label (a vector without its model is unusable for a
    later re-embed), while a question without one must leave the column NULL —
    the QA branch's fail-loud guard counts exactly those NULLs, so persist
    must never fake a value."""
    order = await _make_order(session, target_count=2)
    with_qa = _stub_question(0, embedding_qa=[0.2] * EMBEDDING_DIM)
    without_qa = _stub_question(1)
    assert with_qa.embedding_qa_model is None  # sanity: caller set only the vector

    ctx = _make_ctx(order, [with_qa, without_qa])
    await PersistStage(session_factory).run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    row = await session.get(QuestionRow, uuid.UUID(with_qa.id))
    assert row is not None
    assert row.embedding_qa is not None and len(row.embedding_qa) == EMBEDDING_DIM
    assert row.embedding_qa_model == DEFAULT_EMBEDDING_MODEL
    assert row.embedding is None  # the QA vector never masquerades as the question vector

    row_without = await session.get(QuestionRow, uuid.UUID(without_qa.id))
    assert row_without is not None
    assert row_without.embedding_qa is None
    assert row_without.embedding_qa_model is None

    await _cleanup_order(session, order.id)


@pytest.mark.asyncio
async def test_allocated_subtopic_lands_and_stays_null_when_unsteered(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """#170 D4/170.13: the coverage cell `GenerationStage` allocated is stamped
    on the Question and must reach the row — that column is what the next run's
    coverage map counts, so a lost subtopic means the map never learns what was
    already generated. With steering OFF (the worker's only mode) the column
    must stay NULL rather than pick up a guess: `count(*) WHERE subtopic IS
    NULL` is exactly how the backfill (170.7) finds its work."""
    order = await _make_order(session, target_count=2)
    steered = _stub_question(0, subtopic="volcanology")
    unsteered = _stub_question(1)
    assert unsteered.subtopic is None

    ctx = _make_ctx(order, [steered, unsteered])
    await PersistStage(session_factory).run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    row = await session.get(QuestionRow, uuid.UUID(steered.id))
    assert row is not None
    assert row.subtopic == "volcanology"

    row_unsteered = await session.get(QuestionRow, uuid.UUID(unsteered.id))
    assert row_unsteered is not None
    assert row_unsteered.subtopic is None

    await _cleanup_order(session, order.id)


# ── #182 incremental delivery: persist_batch / finalize / load_existing /
# fail_pack_in_session ──────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_persist_batch_first_call_creates_generating_pack(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """The first persist_batch call is the moment a pack becomes playable —
    it must create the pack row as 'generating' (not the legacy 'complete'
    default), link order.pack_id so a GET on the order can find it, and set
    ctx.pack_id so the caller's next batch resumes on the same pack instead
    of creating a duplicate."""
    order = await _make_order(session, target_count=5)
    order_id = order.id
    ctx = _make_ctx(order, [])
    batch = [_stub_question(i) for i in range(2)]
    stage = PersistStage(session_factory)

    pack = await stage.persist_batch(ctx, batch)

    assert pack.generation_status == "generating"
    assert pack.actual_count == 2
    assert ctx.pack_id == pack.id

    session.expire_all()
    refreshed_order = await session.get(GenerationOrder, order_id)
    assert refreshed_order is not None
    assert refreshed_order.pack_id == pack.id

    await _cleanup_order(session, order_id)


@pytest.mark.asyncio
async def test_persist_batch_second_call_appends_to_same_pack(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """A second accepted batch must land on the SAME pack as the first — a new
    pack per batch would orphan the first batch's already-playable questions
    from the pack id the client keeps polling."""
    order = await _make_order(session, target_count=5)
    ctx = _make_ctx(order, [])
    stage = PersistStage(session_factory)

    batch1 = [_stub_question(i) for i in range(2)]
    pack1 = await stage.persist_batch(ctx, batch1)

    batch2 = [_stub_question(i) for i in range(2, 4)]
    pack2 = await stage.persist_batch(ctx, batch2)

    assert pack2.id == pack1.id
    assert pack2.actual_count == 4

    stmt = select(func.count()).where(QuestionRow.pack_id == pack1.id)
    count = (await session.execute(stmt)).scalar_one()
    assert count == 4

    await _cleanup_order(session, order.id)


@pytest.mark.asyncio
async def test_persist_batch_reinsert_same_ids_is_noop_for_actual_count(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """A retried batch carrying question ids already persisted (e.g. a worker
    retry after a partial failure) must not double-count actual_count — the
    same ON CONFLICT (id) DO NOTHING contract the legacy `run()` path relies
    on for retry safety."""
    order = await _make_order(session, target_count=5)
    ctx = _make_ctx(order, [])
    stage = PersistStage(session_factory)
    batch = [_stub_question(i) for i in range(2)]

    pack1 = await stage.persist_batch(ctx, batch)
    assert pack1.actual_count == 2

    pack2 = await stage.persist_batch(ctx, batch)  # same ids again
    assert pack2.actual_count == 2  # unchanged, not 4

    stmt = select(func.count()).where(QuestionRow.pack_id == pack1.id)
    count = (await session.execute(stmt)).scalar_one()
    assert count == 2

    await _cleanup_order(session, order.id)


@pytest.mark.asyncio
async def test_finalize_marks_pack_complete_and_stamps_generated_at(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """finalize('complete') is what turns a still-generating pack into the
    same shape the legacy single-shot `run()` produces — the live-quiz read
    path must see 'complete' + a generated_at, not a pack stuck announcing
    itself as still in progress after the pipeline is actually done."""
    order = await _make_order(session, target_count=2)
    ctx = _make_ctx(order, [])
    stage = PersistStage(session_factory)
    await stage.persist_batch(ctx, [_stub_question(i) for i in range(2)])

    pack = await stage.finalize(ctx, "complete")

    assert pack is not None
    assert pack.generation_status == "complete"
    assert pack.generated_at is not None

    await _cleanup_order(session, order.id)


@pytest.mark.asyncio
async def test_finalize_with_no_pack_id_is_a_noop(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """A pipeline that fails before ever persisting a single batch has no
    pack to finalize — finalize must return None rather than fabricate a
    pack row or raise on the missing id."""
    order = await _make_order(session, target_count=2)
    ctx = _make_ctx(order, [])  # ctx.pack_id stays None
    stage = PersistStage(session_factory)

    result = await stage.finalize(ctx, "failed")

    assert result is None
    count = (
        await session.execute(
            select(func.count())
            .select_from(QuestionPack)
            .where(QuestionPack.order_id == order.id)
        )
    ).scalar_one()
    assert count == 0

    await _cleanup_order(session, order.id)


@pytest.mark.asyncio
async def test_load_existing_resumes_pack_and_locks_persisted_questions(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """A retried worker attempt must resume on the SAME pack and treat every
    already-persisted question as locked (it may already be in front of a
    player) — load_existing is what rebuilds that state on a fresh ctx
    instead of the retry starting a duplicate pack from scratch."""
    order = await _make_order(session, target_count=4)
    stage = PersistStage(session_factory)
    seed_ctx = _make_ctx(order, [])
    batch1 = [_stub_question(i) for i in range(2)]
    batch2 = [_stub_question(i) for i in range(2, 4)]
    await stage.persist_batch(seed_ctx, batch1)
    await stage.persist_batch(seed_ctx, batch2)
    all_ids = {q.id for q in batch1 + batch2}

    fresh_ctx = _make_ctx(order, [])
    pack = await stage.load_existing(fresh_ctx)

    assert pack is not None
    assert fresh_ctx.pack_id == pack.id
    assert {q.id for q in fresh_ctx.questions} == all_ids
    assert fresh_ctx.locked_count == 4

    await _cleanup_order(session, order.id)


@pytest.mark.asyncio
async def test_load_existing_on_order_without_pack_returns_none(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """A brand-new order has never been persisted to — load_existing must not
    invent a pack or mutate ctx, so the caller falls through to the normal
    first-batch path instead of resuming a pack that doesn't exist."""
    order = await _make_order(session, target_count=4)
    ctx = _make_ctx(order, [])
    stage = PersistStage(session_factory)

    result = await stage.load_existing(ctx)

    assert result is None
    assert ctx.pack_id is None
    assert ctx.questions == []
    assert ctx.locked_count == 0

    await _cleanup_order(session, order.id)


@pytest.mark.asyncio
async def test_fail_pack_in_session_flips_generating_pack_to_failed(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """The worker's final-failure path and the sweep's force-fail paths call
    this inside their own transaction so a pack a player might already be
    reading from isn't left claiming 'generating' forever after its order
    gives up."""
    order = await _make_order(session, target_count=2)
    ctx = _make_ctx(order, [])
    stage = PersistStage(session_factory)
    await stage.persist_batch(ctx, [_stub_question(0)])

    async with session_factory() as s:
        live_order = await s.get(GenerationOrder, order.id)
        assert live_order is not None
        await fail_pack_in_session(s, live_order)
        await s.commit()

    pack = await session.get(QuestionPack, ctx.pack_id)
    assert pack is not None
    assert pack.generation_status == "failed"
    assert pack.generated_at is not None

    await _cleanup_order(session, order.id)


@pytest.mark.asyncio
async def test_fail_pack_in_session_leaves_a_complete_pack_unchanged(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """A pack that already finished must never be clawed back to 'failed' by
    a late-arriving failure signal (e.g. a duplicate sweep tick racing a
    successful delivery) — fail_pack_in_session only touches a 'generating'
    pack."""
    order = await _make_order(session, target_count=1)
    ctx = _make_ctx(order, [])
    stage = PersistStage(session_factory)
    await stage.persist_batch(ctx, [_stub_question(0)])
    await stage.finalize(ctx, "complete")

    async with session_factory() as s:
        live_order = await s.get(GenerationOrder, order.id)
        assert live_order is not None
        await fail_pack_in_session(s, live_order)
        await s.commit()

    pack = await session.get(QuestionPack, ctx.pack_id)
    assert pack is not None
    assert pack.generation_status == "complete"

    await _cleanup_order(session, order.id)


@pytest.mark.asyncio
async def test_fail_pack_in_session_on_order_without_pack_is_a_noop(
    session: AsyncSession,
    session_factory: async_sessionmaker[AsyncSession],
) -> None:
    """An order that fails before ever persisting a batch has no pack —
    fail_pack_in_session must not raise, so the worker/sweep failure paths
    stay uniform whether or not a pack exists yet."""
    order = await _make_order(session, target_count=1)

    async with session_factory() as s:
        live_order = await s.get(GenerationOrder, order.id)
        assert live_order is not None
        await fail_pack_in_session(s, live_order)  # must not raise
        await s.commit()

    await _cleanup_order(session, order.id)
