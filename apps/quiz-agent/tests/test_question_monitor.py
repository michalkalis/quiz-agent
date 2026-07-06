"""QuestionMonitor health check against Postgres (#41 A5/A6).

Why these tests matter: #41 D2 ports the health monitor off ChromaDB onto a
single aggregated query over the canonical pgvector `questions` table. The
admin health endpoint (`GET /api/v1/admin/health`) is the founder's inventory
dashboard — its counts (approved / pending / expired, per difficulty, per
topic) must be derived from Postgres, or the dashboard reports on a store
nothing writes to anymore.

Runs against the dev-stack Postgres (`TEST_DATABASE_URL`, colima #73); the
`questions` table is persistent and shared, so exact-count assertions are
scoped to a unique per-run topic and everything is cleaned up in `finally`.
"""

from __future__ import annotations

import os
import uuid
from datetime import datetime, timedelta, timezone

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.db.engine import build_engine
from app.monitoring.question_monitor import QuestionMonitor
from quiz_shared.database.pgvector_client import EMBEDDING_DIM, PgvectorQuestionStore
from quiz_shared.models.question import Question


def _test_db_url() -> str | None:
    return os.environ.get("TEST_DATABASE_URL")


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


@pytest_asyncio.fixture
async def pg():
    """(store, session_factory) on the test Postgres; engine disposed after."""
    url = _test_db_url()
    if not url:
        pytest.skip("TEST_DATABASE_URL not set — skipping DB-backed test")
    engine = build_engine(url)
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    try:
        yield PgvectorQuestionStore(session_factory=factory), factory
    finally:
        await engine.dispose()


async def _cleanup(factory, ids: list[uuid.UUID]) -> None:
    async with factory() as session:
        await session.execute(
            text("DELETE FROM questions WHERE id = ANY(:ids)"), {"ids": ids}
        )
        await session.commit()


@pytest.mark.asyncio
async def test_check_health_counts_come_from_postgres(pg) -> None:
    """The monitor must classify Postgres rows exactly like the old Chroma
    metadata walk: approved rows drive by_difficulty/by_topic, pending rows
    count separately, and an approved row past `expires_at` counts as expired
    (it still occupies the topic/difficulty buckets, matching the old logic —
    runway is computed off approved-minus-expired)."""
    store, factory = pg
    topic = f"monitor-test-{uuid.uuid4()}"
    ids = [uuid.uuid4() for _ in range(4)]
    approved_easy, approved_hard, pending, expired = ids
    try:
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

        monitor = QuestionMonitor(session_factory=factory)
        status = await monitor.check_health()

        # Exact count only for our unique topic — the test DB is shared.
        assert status.by_topic[topic] == 3  # approved incl. the expired one
        assert status.total_approved >= 3
        assert status.total_pending >= 1
        assert status.total_expired >= 1
        assert status.by_difficulty.get("easy", 0) >= 2
        assert status.by_difficulty.get("hard", 0) >= 1
        # usage_count=60 over the 30-day window → daily usage is estimated,
        # never left at zero, so runway math stays defined.
        assert status.avg_daily_usage > 0
        assert status.checked_at  # ISO timestamp set
        assert any("pending review" in a for a in status.alerts)
    finally:
        await _cleanup(factory, ids)


@pytest.mark.asyncio
async def test_check_health_alerts_on_low_inventory(pg) -> None:
    """A near-empty table must surface a CRITICAL low-inventory alert — the
    monitor's whole purpose is warning before the quiz runs out of questions.
    (The shared test DB holds only rows tests create, i.e. far fewer than the
    CRITICAL_TOTAL=20 threshold.)"""
    _, factory = pg
    monitor = QuestionMonitor(session_factory=factory)
    status = await monitor.check_health()
    assert status.level == "critical"
    assert any("CRITICAL" in a for a in status.alerts)
