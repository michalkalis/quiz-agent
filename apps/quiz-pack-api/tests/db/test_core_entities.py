"""Acceptance tests for issue #33 Task 1.5 — four core ORM tables.

Coverage:
- Pydantic Question → ORM → Pydantic round-trip is value-equal.
- Required indexes (ivfflat embedding, partial pack_id, composite btree) exist
  in `pg_indexes`.
- 50 concurrent `append_step` calls produce 50 unique monotonic event_ids and
  a step_log of length 50 — no events lost to read-modify-write races (R9).
"""

from __future__ import annotations

import asyncio
import os
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import AsyncIterator

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from quiz_shared.models.question import GenerationProvenance, Question

from app.db.engine import build_engine, normalize_async_url
from app.db.models import (
    GenerationJob,
    GenerationOrder,
    QuestionPack,
    QuestionRow,
    append_step,
    question_to_row,
    row_to_question,
)

APP_ROOT = Path(__file__).resolve().parents[2]


def _test_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    return normalize_async_url(url)


@pytest.fixture(scope="module", autouse=True)
def _alembic_head() -> None:
    """Bring the test DB to head once per module so tables exist."""
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


def _make_question(**overrides) -> Question:
    """A fully-populated Pydantic Question for round-trip testing."""
    base = dict(
        id=str(uuid.uuid4()),
        question="What is the capital of France?",
        type="text",
        possible_answers={"a": "Paris", "b": "London", "c": "Berlin", "d": "Rome"},
        correct_answer="Paris",
        alternative_answers=["paris", "paris france"],
        topic="Geography",
        category="adults",
        difficulty="easy",
        tags=["europe", "capitals"],
        language_dependent=False,
        age_appropriate="all",
        language="en",
        pack_id=None,
        prompt_seed="seed1234deadbeef",
        source="generated",
        source_url="https://example.com/paris",
        source_excerpt="Paris is the capital of France.",
        review_status="approved",
        embedding=[0.0] * 1536,
        embedding_model="text-embedding-3-small",
        embedding_dim=1536,
        cost_cents=3,
        usage_count=2,
        created_at=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc),
        expires_at=None,
        freshness_tag=None,
        created_by="admin_1",
        reviewed_by="admin_2",
        reviewed_at=datetime(2026, 1, 2, 9, 0, 0, tzinfo=timezone.utc),
        review_notes="LGTM",
        quality_ratings={
            "surprise_factor": 4,
            "universal_appeal": 5,
            "clever_framing": 4,
            "educational_value": 5,
            "answerability": 5,
        },
        user_ratings={"user_1": 5, "user_2": 4},
        media_url=None,
        image_subtype=None,
        media_duration_seconds=None,
        explanation="France's capital and largest city.",
        generation_metadata=GenerationProvenance(
            model="gpt-4o",
            provider="openai",
            prompt_version="v2",
            pipeline="fact_first",
            generation_temperature=0.7,
            critique_model="gpt-4o-mini",
            critique_score=4.6,
            reasoning_pattern="cot",
            fact_ids=["fact_1", "fact_2"],
            extra={"legacy_key": "legacy_val"},
        ),
    )
    base.update(overrides)
    return Question(**base)


# ── Round-trip Pydantic → ORM → Pydantic ─────────────────────────────────────


@pytest.mark.asyncio
async def test_question_roundtrip_value_equal(session: AsyncSession) -> None:
    q = _make_question()
    row = question_to_row(q)
    session.add(row)
    await session.commit()
    await session.refresh(row)

    fetched = await session.get(QuestionRow, row.id)
    assert fetched is not None
    q2 = row_to_question(fetched)

    # Embedding stored in pgvector (float32) loses precision vs Python float64.
    # Compare separately with approx; clear before model-level equality check.
    assert q.embedding is not None and q2.embedding is not None
    assert q2.embedding == pytest.approx(q.embedding, abs=1e-6)
    q_clean = q.model_copy(update={"embedding": None})
    q2_clean = q2.model_copy(update={"embedding": None})
    assert q_clean == q2_clean

    await session.execute(text("DELETE FROM questions WHERE id = :id"), {"id": row.id})
    await session.commit()


@pytest.mark.asyncio
async def test_question_roundtrip_minimal(session: AsyncSession) -> None:
    """Required-fields-only Question — Pydantic defaults must survive the seam."""
    minimal = Question(
        id=str(uuid.uuid4()),
        question="Is the sky blue?",
        correct_answer="yes",
        topic="Science",
        category="general",
        difficulty="easy",
        created_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
    )
    row = question_to_row(minimal)
    session.add(row)
    await session.commit()
    await session.refresh(row)

    fetched = await session.get(QuestionRow, row.id)
    assert fetched is not None
    back = row_to_question(fetched)
    assert back == minimal

    await session.execute(text("DELETE FROM questions WHERE id = :id"), {"id": row.id})
    await session.commit()


# ── Index existence smoke ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_required_indexes_exist(session: AsyncSession) -> None:
    result = await session.execute(
        text(
            "SELECT indexname FROM pg_indexes "
            "WHERE tablename = 'questions' AND indexname = ANY(:names)"
        ),
        {
            "names": [
                "ix_questions_pack_id",
                "ix_questions_language_category_review_status",
                "ix_questions_embedding_ivfflat",
            ]
        },
    )
    names = {row.indexname for row in result.all()}
    assert names == {
        "ix_questions_pack_id",
        "ix_questions_language_category_review_status",
        "ix_questions_embedding_ivfflat",
    }

    # And the ivfflat one is actually using ivfflat, not a default btree.
    detail = await session.execute(
        text(
            "SELECT indexdef FROM pg_indexes "
            "WHERE indexname = 'ix_questions_embedding_ivfflat'"
        )
    )
    indexdef = detail.scalar_one()
    assert "ivfflat" in indexdef
    assert "vector_cosine_ops" in indexdef


# ── Concurrent append_step ────────────────────────────────────────────────────


async def _make_order_and_job(session: AsyncSession) -> tuple[uuid.UUID, uuid.UUID]:
    order = GenerationOrder(
        transaction_id=f"txn_{uuid.uuid4().hex}",
        product_id="pack_10",
        prompt="test prompt that meets minimum length requirement",
        target_count=10,
        language="en",
        status="in_progress",
    )
    session.add(order)
    await session.flush()
    job = GenerationJob(order_id=order.id, status="queued")
    session.add(job)
    await session.commit()
    return order.id, job.id


@pytest.mark.asyncio
async def test_append_step_concurrent_no_lost_events(
    engine: AsyncEngine, session: AsyncSession
) -> None:
    order_id, job_id = await _make_order_and_job(session)

    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

    async def one_call(i: int) -> int:
        async with factory() as s:
            evt_id = await append_step(
                s, job_id, step=f"step_{i}", info={"i": i}
            )
            await s.commit()
            return evt_id

    results = await asyncio.gather(*(one_call(i) for i in range(50)))
    assert len(results) == 50
    assert sorted(results) == list(range(50))  # unique, monotonic 0..49

    # And the persisted step_log has 50 entries with matching event_ids.
    row = await session.execute(
        text("SELECT step_log FROM generation_jobs WHERE id = :id"),
        {"id": job_id},
    )
    step_log = row.scalar_one()
    assert isinstance(step_log, list)
    assert len(step_log) == 50
    event_ids = [entry["event_id"] for entry in step_log]
    assert sorted(event_ids) == list(range(50))
    # event_id within each entry matches its array position (in-order append).
    assert event_ids == list(range(50))

    # Cleanup.
    await session.execute(
        text("DELETE FROM generation_orders WHERE id = :id"),
        {"id": order_id},
    )
    await session.commit()


# ── ORM-level table+constraint smoke ──────────────────────────────────────────


@pytest.mark.asyncio
async def test_order_status_check_constraint(session: AsyncSession) -> None:
    bad = GenerationOrder(
        transaction_id=f"txn_{uuid.uuid4().hex}",
        product_id="pack_10",
        prompt="prompt that is long enough",
        target_count=10,
        language="en",
        status="bogus_status",
    )
    session.add(bad)
    with pytest.raises(Exception):
        await session.commit()
    await session.rollback()


@pytest.mark.asyncio
async def test_pack_insert_and_link(session: AsyncSession) -> None:
    order = GenerationOrder(
        transaction_id=f"txn_{uuid.uuid4().hex}",
        product_id="pack_10",
        prompt="prompt long enough for the test",
        target_count=10,
        language="en",
    )
    session.add(order)
    await session.flush()
    pack = QuestionPack(
        order_id=order.id,
        prompt=order.prompt,
        language=order.language,
        target_count=order.target_count,
        actual_count=10,
        generated_at=datetime.now(timezone.utc),
    )
    session.add(pack)
    await session.commit()
    order.pack_id = pack.id
    await session.commit()

    fetched_pack = await session.get(QuestionPack, pack.id)
    fetched_order = await session.get(GenerationOrder, order.id)
    assert fetched_pack is not None and fetched_order is not None
    assert fetched_order.pack_id == fetched_pack.id

    await session.execute(
        text("DELETE FROM generation_orders WHERE id = :id"),
        {"id": order.id},
    )
    await session.commit()
