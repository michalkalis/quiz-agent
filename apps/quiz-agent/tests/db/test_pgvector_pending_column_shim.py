"""The pgvector mirror must survive a not-yet-migrated database (#133 V7).

Deploy-order hazard this guards: `questions.headline_answer` arrives with
quiz-pack-api migration b4d9e17c3a52, which is founder-gated
(migrate-before-deploy), while quiz-agent deploys on its own cadence. The
mirror in `quiz_shared.database.pgvector_client` names every column it selects,
so a quiz-agent build shipped *before* the migration would fail EVERY question
read with `UndefinedColumn` — the voice quiz would not serve at all.

Both directions are exercised against throwaway schemas, because "it works on
my migrated laptop" is exactly the state that hides this class of outage. When
the column is gone the store must still read and write, return no gist, and say
out loud which migration is missing rather than degrading quietly.

Delete this file together with the shim once b4d9e17c3a52 is applied in staging
and prod.
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone

import pytest
import pytest_asyncio
from sqlalchemy import MetaData, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.db.engine import build_engine
from quiz_shared.database.pgvector_client import (
    EMBEDDING_DIM,
    PENDING_COLUMN,
    PENDING_MIGRATION,
    PgvectorQuestionStore,
    questions_table,
)
from quiz_shared.models.question import Question
from tests.conftest import require_db_url

SHIM_LOGGER = "quiz_shared.database.pgvector_client"
GIST = "Italy's national racing colour"


def _open_question() -> Question:
    return Question(
        id=str(uuid.uuid4()),
        question="Why are Ferraris red?",
        type="text",
        correct_answer="Red was the racing colour assigned to Italy in the 1900s.",
        headline_answer=GIST,
        topic="Cars",
        category="adults",
        difficulty="medium",
        review_status="approved",
        # Embedding carried on the Question so the store never calls OpenAI.
        embedding=[1.0] + [0.0] * (EMBEDDING_DIM - 1),
        embedding_model="test-fixture",
        embedding_dim=EMBEDDING_DIM,
        created_at=datetime.now(timezone.utc),
    )


@pytest_asyncio.fixture
async def scratch_store(request):
    """A store pinned to a throwaway schema holding a copy of the mirror table.

    ``request.param`` decides whether that copy has ``headline_answer``. The
    table is always created, so an unqualified ``questions`` can never fall
    through the search_path onto the real corpus table.
    """
    with_column: bool = request.param
    url = require_db_url("pgvector pending-column shim")
    schema = f"shim_{uuid.uuid4().hex[:8]}"

    admin = build_engine(url)
    metadata = MetaData(schema=schema)
    questions_table.to_metadata(metadata)
    async with admin.begin() as conn:
        await conn.execute(text(f'CREATE SCHEMA "{schema}"'))
        await conn.run_sync(metadata.create_all)
        if not with_column:
            await conn.execute(
                text(f'ALTER TABLE "{schema}".questions DROP COLUMN {PENDING_COLUMN}')
            )

    # public stays on the path only so the `vector` type resolves; the scratch
    # schema is first, so `questions` always means the copy.
    scoped = create_async_engine(
        admin.url.render_as_string(hide_password=False),
        connect_args={"server_settings": {"search_path": f"{schema},public"}},
    )
    factory = async_sessionmaker(scoped, class_=AsyncSession, expire_on_commit=False)
    try:
        yield PgvectorQuestionStore(session_factory=factory)
    finally:
        await scoped.dispose()
        async with admin.begin() as conn:
            await conn.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        await admin.dispose()


@pytest.mark.asyncio
@pytest.mark.parametrize("scratch_store", [True], indirect=True)
async def test_migrated_database_round_trips_the_gist(scratch_store) -> None:
    """Column present (the post-migration steady state): gist persists."""
    q = _open_question()
    assert await scratch_store.add(q) is True

    fetched = await scratch_store.get(q.id)
    assert fetched is not None
    assert fetched.headline_answer == GIST


@pytest.mark.asyncio
@pytest.mark.parametrize("scratch_store", [False], indirect=True)
async def test_unmigrated_database_still_serves_and_warns(
    scratch_store, caplog
) -> None:
    """Column absent (quiz-agent deployed ahead of the migration): the read path
    keeps working, the gist is simply absent, and the warning names the fix."""
    q = _open_question()
    with caplog.at_level(logging.WARNING, logger=SHIM_LOGGER):
        assert await scratch_store.add(q) is True

        fetched = await scratch_store.get(q.id)
        assert fetched is not None, "read must not fail on an unmigrated DB"
        assert fetched.question == "Why are Ferraris red?"
        assert fetched.headline_answer is None

        # Every read path is narrowed, not just `get` — a single un-narrowed
        # SELECT would still take the app down.
        assert [x.id for x in await scratch_store.get_all()] == [q.id]
        assert [x.id for x in await scratch_store.search(n_results=5)] == [q.id]
        assert await scratch_store.count() == 1

    warnings = [
        r.getMessage() for r in caplog.records if r.levelno >= logging.WARNING
    ]
    assert any(
        PENDING_MIGRATION in w and PENDING_COLUMN in w for w in warnings
    ), warnings
    # Probed once, not once per query.
    assert sum(PENDING_MIGRATION in w for w in warnings) == 1
