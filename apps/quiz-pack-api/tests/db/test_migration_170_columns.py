"""#170 migration a170c0e5d1b2 (task 170.4, A2) — live-DB test.

Why this matters: the migration is class `b` (touches the prod schema) and
must be *backwards compatible* — nothing in the pipeline switches on because
of it. So we assert (a) the four columns and two btree indexes exist after
`alembic upgrade head`, (b) there is NO vector index on `embedding_qa`
(D9), (c) `PersistStage` still writes a row with every new column NULL, and
(d) downgrade removes everything again. If (c) regressed, every existing
direct/CLI run would break on the day the founder applies the migration.

Needs TEST_DATABASE_URL (`make dev-db`); skipped otherwise, like test_persist.
"""

from __future__ import annotations

import glob
import os
import subprocess
import sys
import uuid
from pathlib import Path

import pytest
import pytest_asyncio
from app.db.engine import build_engine, normalize_async_url
from app.db.models import GenerationOrder, QuestionPack, QuestionRow
from app.orchestrator import OrderContext
from app.orchestrator.stages.persist import PersistStage
from quiz_shared.models.question import Question
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

APP_ROOT = Path(__file__).resolve().parents[2]
NEW_COLUMNS = ("subtopic", "answer_key", "embedding_qa", "embedding_qa_model")
NEW_INDEXES = (
    "ix_questions_lang_category_subtopic",
    "ix_questions_lang_category_answer_key",
)


class _NullSink:
    """ProgressSink double — PersistStage never calls it, the protocol requires it."""

    async def start_step(self, step, info=None):
        return 0

    async def finish_step(self, *args, **kwargs):
        return None

    async def publish(self, *args, **kwargs):
        return None


def _raw_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    return url


def _alembic(*args: str) -> None:
    env = os.environ.copy()
    env["DATABASE_URL"] = _raw_url()
    subprocess.run(
        [sys.executable, "-m", "alembic", *args],
        cwd=APP_ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )


@pytest.fixture(scope="module", autouse=True)
def _alembic_head() -> None:
    _alembic("upgrade", "head")


@pytest_asyncio.fixture
async def engine() -> AsyncEngine:
    eng = build_engine(normalize_async_url(_raw_url()))
    try:
        yield eng
    finally:
        await eng.dispose()


async def _columns(engine: AsyncEngine) -> dict[str, str]:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text(
                "SELECT column_name, udt_name FROM information_schema.columns "
                "WHERE table_name = 'questions'"
            )
        )
        return {r[0]: r[1] for r in rows}


async def _indexes(engine: AsyncEngine) -> dict[str, str]:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text(
                "SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'questions'"
            )
        )
        return {r[0]: r[1] for r in rows}


def test_exactly_one_170_revision_file_without_hnsw() -> None:
    files = glob.glob(str(APP_ROOT / "alembic" / "versions" / "*170*.py"))
    assert len(files) == 1, files
    source = Path(files[0]).read_text(encoding="utf-8").lower()
    assert "hnsw" not in source and "ivfflat" not in source.split("def upgrade")[1]


@pytest.mark.asyncio
async def test_columns_and_btree_indexes_exist_after_upgrade(
    engine: AsyncEngine,
) -> None:
    cols = await _columns(engine)
    for name in NEW_COLUMNS:
        assert name in cols, f"missing column {name}"
    assert cols["embedding_qa"] == "vector"
    idx = await _indexes(engine)
    for name in NEW_INDEXES:
        assert name in idx, f"missing index {name}"
        assert "USING btree" in idx[name]
    # D9: no vector index on the QA column, ever, in this migration.
    assert not any("embedding_qa" in d for d in idx.values())


@pytest.mark.asyncio
async def test_persist_still_writes_rows_with_new_columns_null(
    engine: AsyncEngine,
) -> None:
    """Backwards compatibility: a pipeline that knows nothing about #170 keeps
    persisting exactly as before, and the new columns simply stay NULL."""
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    order = GenerationOrder(
        transaction_id=f"170-compat-{uuid.uuid4().hex}",
        product_id="pack_10",
        prompt="170 migration compat",
        category="science-nature",
        target_count=1,
        language="en",
        status="in_progress",
    )
    async with factory() as session:
        session.add(order)
        await session.commit()
        order_id = order.id

    q = Question.from_dict(
        {
            "id": str(uuid.uuid4()),
            "question": "Which planet is known as the Red Planet?",
            "type": "text",
            "correct_answer": "Mars",
            "topic": "Space",
            "category": "science-nature",
            "difficulty": "easy",
        }
    )
    ctx = OrderContext(
        order_id=order_id,
        prompt="170 migration compat",
        language="en",
        target_count=1,
        category="science-nature",
    )
    ctx.questions = [q]
    await PersistStage(factory).run(ctx, sink=_NullSink())  # type: ignore[arg-type]

    async with factory() as session:
        row = await session.get(QuestionRow, uuid.UUID(q.id))
        assert row is not None
        assert row.subtopic is None and row.answer_key is None
        assert row.embedding_qa is None and row.embedding_qa_model is None
        # cleanup so the module leaves the test DB as it found it
        await session.delete(row)
        pack = await session.get(QuestionPack, ctx.pack_id)
        if pack is not None:
            await session.delete(pack)
        order = await session.get(GenerationOrder, order_id)
        if order is not None:
            await session.delete(order)
        await session.commit()


@pytest.mark.asyncio
async def test_downgrade_drops_columns_and_indexes(engine: AsyncEngine) -> None:
    _alembic("downgrade", "f2a91c4b8e57")
    try:
        cols = await _columns(engine)
        assert not any(name in cols for name in NEW_COLUMNS)
        idx = await _indexes(engine)
        assert not any(name in idx for name in NEW_INDEXES)
    finally:
        _alembic("upgrade", "head")
