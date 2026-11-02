"""Public fresh-questions selection against a real Postgres (#223).

The endpoint has no login, so the SQL is the only gate between the website and
the corpus. Each test proves a row class that must NEVER reach a public page:
custom-pack questions, unreviewed ones, stale (unboosted/expired boost) ones,
expired ones, other-language ones, and rows a page cannot show properly (no
explanation, non-https source). Private scratch DB per test; skips without
`TEST_DATABASE_URL` unless `REQUIRE_DB_TESTS=1`.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from urllib.parse import urlsplit, urlunsplit

import asyncpg
import pytest
import pytest_asyncio
from app.db.engine import build_engine, normalize_async_url
from quiz_shared.database.pgvector_client import (
    EMBEDDING_DIM,
    PgvectorQuestionStore,
    questions_table,
)
from quiz_shared.models.question import Question
from sqlalchemy import text, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from tests.conftest import require_db_url

NOW = datetime.now(UTC)
FRESH = NOW + timedelta(days=10)


def _question(**overrides) -> Question:
    fields = {
        "id": str(uuid.uuid4()),
        "question": "Fresh fixture?",
        "type": "text",
        "correct_answer": "42",
        "topic": "fresh-test",
        "category": "entertainment",
        "difficulty": "easy",
        "review_status": "approved",
        "source": "generated",
        "source_url": "https://example.org/a",
        "explanation": "Because.",
        "language": "sk",
        "boost_until": FRESH,
        "embedding": [1.0] + [0.0] * (EMBEDDING_DIM - 1),
        "embedding_model": "test-fixture",
        "embedding_dim": EMBEDDING_DIM,
        "created_at": NOW,
    }
    fields.update(overrides)
    return Question(**fields)


@pytest_asyncio.fixture
async def store():
    parts = urlsplit(normalize_async_url(require_db_url("public fresh questions")))
    dbname = f"quiz_agent_fresh_{uuid.uuid4().hex[:10]}"
    admin_dsn = urlunsplit(parts._replace(path="/postgres")).replace(
        "postgresql+asyncpg://", "postgresql://", 1
    )
    scratch_url = urlunsplit(parts._replace(path=f"/{dbname}"))
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


async def _ids(store, language="sk", limit=20) -> set[str]:
    rows = await store.fresh_public_entertainment(language, limit)
    return {r["id"] for r in rows}


@pytest.mark.asyncio
async def test_only_publicly_servable_fresh_rows_leave_the_building(store):
    """Anything the app would not serve, or a page could not show, stays out."""
    store, factory = store
    good = _question()
    excluded = {
        "pack": _question(),
        "no_embedding": _question(),
        "not_text": _question(),
        "pending": _question(review_status="pending_review"),
        "never_boosted": _question(boost_until=None),
        "boost_over": _question(boost_until=NOW - timedelta(days=1)),
        "expired": _question(expires_at=NOW - timedelta(days=1)),
        "other_category": _question(category="history"),
        "other_language": _question(language="cs"),
        "no_explanation": _question(explanation="  "),
        "http_source": _question(source_url="http://example.org/a"),
        "no_source": _question(source_url=None),
    }
    for q in [good, *excluded.values()]:
        assert await store.upsert(q) is True
    # Columns the Question model cannot express, set directly on the mirror table.
    tweaks = {
        "pack": {"pack_id": uuid.uuid4()},
        "no_embedding": {"embedding": None},
        "not_text": {"type": "image"},
    }
    async with factory() as s:
        for key, values in tweaks.items():
            await s.execute(
                update(questions_table)
                .where(questions_table.c.id == uuid.UUID(excluded[key].id))
                .values(**values)
            )
        await s.commit()

    assert await _ids(store) == {good.id}


@pytest.mark.asyncio
async def test_english_includes_legacy_null_language_but_sk_does_not(store):
    """Legacy rows with language NULL are English; they must not appear in sk."""
    store, _ = store
    en = _question(language="en")
    legacy = _question(language=None)
    sk = _question(language="sk")
    for q in (en, legacy, sk):
        await store.upsert(q)

    assert await _ids(store, "en") == {en.id, legacy.id}
    assert await _ids(store, "sk") == {sk.id}


@pytest.mark.asyncio
async def test_newest_first_and_limit_respected(store):
    store, _ = store
    old = _question(created_at=NOW - timedelta(days=3))
    mid = _question(created_at=NOW - timedelta(days=1))
    new = _question(created_at=NOW)
    for q in (old, new, mid):
        await store.upsert(q)

    rows = await store.fresh_public_entertainment("sk", 2)

    assert [r["id"] for r in rows] == [new.id, mid.id]
