"""QuestionMonitor health check against Postgres (#41 A5/A6).

Why these tests matter: #41 D2 ports the health monitor off ChromaDB onto a
single aggregated query over the canonical pgvector `questions` table. The
admin health endpoint (`GET /api/v1/admin/health`) is the founder's inventory
dashboard — its counts (approved / pending / expired, per difficulty, per
topic) must be derived from Postgres, or the dashboard reports on a store
nothing writes to anymore.

Isolation: `check_health` aggregates the WHOLE table and takes no filter, so its
counts and alerts cannot be asserted honestly against the shared persistent test
DB. `level == "critical"` there was really asserting "whatever rows other suites
left behind happen to add up to fewer than 20 approved" — it would flip the day
the shared DB got seeded, and it never distinguished the low-inventory alert from
the empty-table one. Each test below therefore gets a PRIVATE scratch database
holding only the rows it creates, which makes every count exact and lets the
alert thresholds be pinned for real.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from urllib.parse import urlsplit, urlunsplit

import asyncpg
import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.db.engine import build_engine, normalize_async_url
from app.monitoring.question_monitor import CRITICAL_TOTAL, QuestionMonitor
from quiz_shared.database.pgvector_client import (
    EMBEDDING_DIM,
    PgvectorQuestionStore,
    questions_table,
)
from quiz_shared.models.question import Question
from tests.conftest import require_db_url


def _make_question(qid: uuid.UUID, topic: str, **overrides) -> Question:
    fields = dict(
        id=str(qid),
        question=f"Monitor fixture {qid}?",
        type="text",
        correct_answer="42",
        topic=topic,
        category="general",
        difficulty="easy",
        review_status="approved",
        source="generated",
        usage_count=0,
        # Embedding carried on the Question so the store never calls OpenAI.
        embedding=[1.0] + [0.0] * (EMBEDDING_DIM - 1),
        embedding_model="test-fixture",
        embedding_dim=EMBEDDING_DIM,
        created_at=datetime.now(timezone.utc),
    )
    fields.update(overrides)
    return Question(**fields)


def _scratch_urls() -> tuple[str, str, str]:
    """(admin dsn, scratch url, db name) derived from TEST_DATABASE_URL."""
    parts = urlsplit(normalize_async_url(require_db_url("QuestionMonitor tests")))
    dbname = f"quiz_agent_monitor_{uuid.uuid4().hex[:10]}"
    admin = urlunsplit(parts._replace(path="/postgres")).replace(
        "postgresql+asyncpg://", "postgresql://", 1
    )
    return admin, urlunsplit(parts._replace(path=f"/{dbname}")), dbname


@pytest_asyncio.fixture
async def pg():
    """(store, session_factory) on a private database holding ONLY this test's
    rows — the monitor counts everything, so nothing else may be in there.

    Only the `questions` table is created (it is alembic-managed by
    quiz-pack-api, but its SQLAlchemy definition is the same one the monitor
    queries), which keeps the scratch DB cheap.
    """
    admin_dsn, scratch_url, dbname = _scratch_urls()

    conn = await asyncpg.connect(admin_dsn)
    try:
        await conn.execute(f'CREATE DATABASE "{dbname}"')
    finally:
        await conn.close()

    engine = build_engine(scratch_url)
    try:
        async with engine.begin() as db_conn:
            await db_conn.execute(text("CREATE EXTENSION IF NOT EXISTS vector"))
            await db_conn.run_sync(questions_table.metadata.create_all)
        factory = async_sessionmaker(
            engine, class_=AsyncSession, expire_on_commit=False
        )
        yield PgvectorQuestionStore(session_factory=factory), factory
    finally:
        await engine.dispose()
        conn = await asyncpg.connect(admin_dsn)
        try:
            await conn.execute(
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                "WHERE datname = $1 AND pid <> pg_backend_pid()",
                dbname,
            )
            await conn.execute(f'DROP DATABASE IF EXISTS "{dbname}"')
        finally:
            await conn.close()


@pytest.mark.asyncio
async def test_check_health_counts_come_from_postgres(pg) -> None:
    """The monitor must classify Postgres rows exactly like the old Chroma
    metadata walk: approved rows drive by_difficulty/by_topic, pending rows
    count separately, and an approved row past `expires_at` counts as expired
    (it still occupies the topic/difficulty buckets, matching the old logic —
    runway is computed off approved-minus-expired).

    Every count is asserted EXACTLY: four known rows in a private DB, so a
    misclassified review_status or a double-counting bucket cannot hide behind
    a `>=`.
    """
    store, factory = pg
    topic = "monitor-test"
    approved_easy, approved_hard, pending, expired = (uuid.uuid4() for _ in range(4))

    assert await store.upsert(_make_question(approved_easy, topic)) is True
    assert (
        await store.upsert(
            _make_question(approved_hard, topic, difficulty="hard", usage_count=60)
        )
        is True
    )
    assert (
        await store.upsert(
            _make_question(pending, topic, review_status="pending_review")
        )
        is True
    )
    assert (
        await store.upsert(
            _make_question(
                expired,
                topic,
                expires_at=datetime.now(timezone.utc) - timedelta(days=1),
            )
        )
        is True
    )

    status = await QuestionMonitor(session_factory=factory).check_health()

    # Approved rows only, the expired one included — the buckets are "what
    # exists", runway is what nets the expired row out.
    assert status.by_topic == {topic: 3}
    assert status.by_difficulty == {"easy": 2, "hard": 1}
    assert status.total_approved == 3
    assert status.total_pending == 1  # pending_review is NOT approved inventory
    assert status.total_expired == 1

    # usage_count 60 spread over the 30-day window, so daily usage is estimated
    # rather than left at zero and the runway stays defined: 2 active approved
    # (3 minus the expired one) at 2.0/day = 1 day of questions left.
    assert status.avg_daily_usage == 2.0
    assert status.runway_days == 1.0
    assert status.checked_at  # ISO timestamp set
    # Pending rows are surfaced for review, not silently held back.
    assert any("pending review" in a for a in status.alerts)


@pytest.mark.asyncio
async def test_check_health_alerts_on_low_inventory(pg) -> None:
    """A stocked-but-thin table must raise the CRITICAL low-inventory alert —
    warning before the quiz runs out of questions is the monitor's whole purpose.

    Three approved rows: non-empty, so this is genuinely the
    `active_approved < CRITICAL_TOTAL` branch and not the separate
    "no questions at all" one.
    """
    store, factory = pg
    for _ in range(3):
        assert await store.upsert(_make_question(uuid.uuid4(), "low-inventory")) is True

    status = await QuestionMonitor(session_factory=factory).check_health()

    assert status.total_approved == 3
    assert status.level == "critical"
    assert any("CRITICAL" in a and "active approved" in a for a in status.alerts)
    assert not any("No questions in database" in a for a in status.alerts)


@pytest.mark.asyncio
async def test_inventory_at_the_threshold_is_not_critical(pg) -> None:
    """The other side of the same boundary. The gate is `< CRITICAL_TOTAL`, so
    exactly CRITICAL_TOTAL active approved questions is still healthy inventory.
    Without this, the threshold could drift upward and the dashboard would cry
    CRITICAL over a perfectly stocked corpus.
    """
    store, factory = pg
    for _ in range(CRITICAL_TOTAL):
        assert await store.upsert(_make_question(uuid.uuid4(), "at-threshold")) is True

    status = await QuestionMonitor(session_factory=factory).check_health()

    assert status.total_approved == CRITICAL_TOTAL
    assert status.total_expired == 0
    assert not any("CRITICAL" in a for a in status.alerts)
    assert status.level != "critical"


@pytest.mark.asyncio
async def test_empty_table_reports_no_questions(pg) -> None:
    """An empty table is its own CRITICAL, reported before any threshold math.

    This is the branch the previously-ambient assertions could hit by accident
    (a freshly wiped shared DB) while claiming to test low inventory — pinning it
    separately keeps the two failure modes distinguishable on the dashboard.
    """
    _, factory = pg

    status = await QuestionMonitor(session_factory=factory).check_health()

    assert status.level == "critical"
    assert any("No questions in database" in a for a in status.alerts)
    assert status.total_approved == 0
    assert status.runway_days == 0.0
