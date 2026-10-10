"""Question stock counts against a real Postgres (#199).

The unit tests in `tests/test_question_stock.py` pin the filters the check sends;
this proves the filters mean what the alert claims once they reach SQL:

- fresh = boosted past the horizon, NOT permanent (9999-01-01), NOT already
  expired, approved only;
- the per-cell count follows the retriever's own sk/cs rule (translated English
  rows count unless language-dependent; native rows count in their language).

Each test gets a PRIVATE scratch database holding only its own rows, so every
count is exact (the shared test DB is persistent and cannot be asserted on with
`==`). Skips without `TEST_DATABASE_URL` unless `REQUIRE_DB_TESTS=1`.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from urllib.parse import urlsplit, urlunsplit

import asyncpg
import pytest
import pytest_asyncio
from app.config import Settings
from app.db.engine import build_engine, normalize_async_url
from app.monitoring.question_stock import fetch_question_stock
from app.retrieval.question_retriever import QuestionRetriever
from quiz_shared.database.pgvector_client import (
    EMBEDDING_DIM,
    PgvectorQuestionStore,
    questions_table,
)
from quiz_shared.models.question import Question
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from tests.conftest import require_db_url

NOW = datetime.now(UTC)
PERMANENT = datetime(9999, 1, 1, tzinfo=UTC)


def _question(category: str = "entertainment", **overrides) -> Question:
    fields = {
        "id": str(uuid.uuid4()),
        "question": "Stock fixture?",
        "type": "text",
        "correct_answer": "42",
        "topic": "stock-test",
        "category": category,
        "difficulty": "easy",
        "review_status": "approved",
        "source": "generated",
        # Embedding on the row: a servable question must have one.
        "embedding": [1.0] + [0.0] * (EMBEDDING_DIM - 1),
        "embedding_model": "test-fixture",
        "embedding_dim": EMBEDDING_DIM,
        "created_at": NOW,
    }
    fields.update(overrides)
    return Question(**fields)


def _scratch_urls() -> tuple[str, str, str]:
    parts = urlsplit(normalize_async_url(require_db_url("question stock counts")))
    dbname = f"quiz_agent_stock_{uuid.uuid4().hex[:10]}"
    admin = urlunsplit(parts._replace(path="/postgres")).replace(
        "postgresql+asyncpg://", "postgresql://", 1
    )
    return admin, urlunsplit(parts._replace(path=f"/{dbname}")), dbname


@pytest_asyncio.fixture
async def store():
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
        yield PgvectorQuestionStore(session_factory=factory)
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


async def _stock(store: PgvectorQuestionStore, *languages: str):
    report = await fetch_question_stock(
        QuestionRetriever(question_store=store),
        Settings(),
        now=NOW,
        languages=languages,
    )
    return {lang.language: lang for lang in report.languages}


@pytest.mark.asyncio
async def test_fresh_counts_only_finite_boosts_that_outlive_the_horizon(store):
    """The whole point of the fresh alert: a stock that will still be boosted
    in 14 days. Permanent boosts never run out and short ones are gone before
    new questions can be generated, so neither may pad the number."""
    rows = {
        "long": _question(boost_until=NOW + timedelta(days=30)),
        "ends_inside_horizon": _question(boost_until=NOW + timedelta(days=7)),
        "permanent": _question(boost_until=PERMANENT),
        "never_boosted": _question(),
        "boost_expired": _question(boost_until=NOW - timedelta(days=1)),
        "unapproved": _question(
            boost_until=NOW + timedelta(days=30), review_status="pending_review"
        ),
        "other_category": _question(
            category="history", boost_until=NOW + timedelta(days=30)
        ),
    }
    for q in rows.values():
        assert await store.upsert(q) is True

    en = (await _stock(store, "en"))["en"]

    assert en.fresh_entertainment == 1  # only "long"
    # Approved entertainment of any boost state still counts as playable stock.
    assert en.categories["entertainment"] == 5
    assert en.categories["history"] == 1


@pytest.mark.asyncio
async def test_slovak_stock_follows_the_serve_rule_for_translated_and_native_rows(
    store,
):
    """A Slovak session is served native sk rows plus English rows that carry
    no wordplay. A language-dependent English row must not inflate Slovak stock
    (it would break in translation), and a Czech row never counts for Slovak."""
    boosted = NOW + timedelta(days=30)
    await store.upsert(_question(language="en", boost_until=boosted))
    await store.upsert(
        _question(language="en", language_dependent=True, boost_until=boosted)
    )
    await store.upsert(_question(language="sk", boost_until=boosted))
    await store.upsert(_question(language="cs", boost_until=boosted))

    stock = await _stock(store, "en", "sk", "cs")

    assert stock["en"].fresh_entertainment == 2  # both English rows
    assert stock["sk"].fresh_entertainment == 2  # plain English + native sk
    assert stock["cs"].fresh_entertainment == 2  # plain English + native cs
    assert stock["sk"].categories["entertainment"] == 2
