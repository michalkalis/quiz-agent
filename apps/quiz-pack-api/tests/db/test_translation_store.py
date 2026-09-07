"""Database-enforced invariants of the translation store (#168 — batch
translation pipeline SK/CS, DD3).

WHY these three, not a column inventory: each one is a *serving-correctness*
invariant that no test elsewhere can catch, because the failure mode is silent.

1. One live row per (question, language). Retranslation overwrites the row and
   drops it back to `pending`. If two rows could coexist for one pair, the
   reader would pick an arbitrary one — and the pipeline could leave a
   superseded `approved` draft next to a fresh `pending` one, serving text
   nobody re-verified. The UNIQUE index is what makes this the database's
   guarantee rather than a convention the runner is trusted to keep.

2. Deleting a question takes its translations (and their corrections) with it.
   The production correction workflow for exactly the edit class DD3 worries
   about is delete-then-reimport (`scripts/apply_corrections_production.py`).
   Without ON DELETE CASCADE that workflow would either fail on the FK or,
   worse, strand a translation of text that no longer exists; with it, the
   re-imported row correctly starts out approved in no language.

3. A question written by a path that knows nothing about translation starts
   `approved_languages = '{}'`. That server default is the entire reason the
   migration is safe to apply *before* the deploy (DD4/C2) — every pre-existing
   row silently acquires the pre-migration truth, "approved in no non-English
   language", and the serving filter never has to reason about NULL.
"""

from __future__ import annotations

import os
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from contextlib import asynccontextmanager
from typing import AsyncIterator

import pytest
import pytest_asyncio
from sqlalchemy import delete, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.db.engine import build_engine, normalize_async_url
from app.db.models import (
    QuestionRow,
    QuestionTranslation,
    QuestionTranslationCorrection,
)

APP_ROOT = Path(__file__).resolve().parents[2]


def _test_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    return normalize_async_url(url)


@pytest.fixture(scope="module", autouse=True)
def _alembic_head() -> None:
    """Bring the test DB to head once per module so the tables exist."""
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


def _question_row() -> QuestionRow:
    """A minimal English source question — only the NOT NULL columns matter."""
    return QuestionRow(
        id=uuid.uuid4(),
        question="Which country's national racing colour was red?",
        type="text",
        correct_answer="Italy",
        topic="motorsport",
        category="hobbies-interests",
        difficulty="medium",
        created_at=datetime.now(timezone.utc),
    )


def _translation(question_id: uuid.UUID, language: str) -> QuestionTranslation:
    return QuestionTranslation(
        id=uuid.uuid4(),
        question_id=question_id,
        language=language,
        question="Ktorá krajina mala národnú pretekársku farbu červenú?",
        correct_answer="Taliansko",
        model="claude-opus-5",
        prompt_version="v1",
        source_hash="0" * 64,
    )


@asynccontextmanager
async def seeded_question(session: AsyncSession) -> AsyncIterator[QuestionRow]:
    """Insert one source question and remove it again.

    A context manager rather than a fixture on purpose: teardown must run
    inside the test coroutine, while the session's event loop is still alive.
    """
    row = _question_row()
    # Held separately: `rollback()` below expires the instance, and reading an
    # attribute off an expired object would emit lazy (sync) IO from teardown.
    row_id = row.id
    session.add(row)
    await session.commit()
    try:
        yield row
    finally:
        await session.rollback()
        await session.execute(delete(QuestionRow).where(QuestionRow.id == row_id))
        await session.commit()


async def test_a_language_cannot_have_two_live_translations(
    session: AsyncSession,
) -> None:
    """A second draft for the same (question, language) must be refused.

    Retranslation is an overwrite, not an insert. If both rows could exist, an
    unverified draft could sit beside an approved one and be served.
    """
    async with seeded_question(session) as source:
        # Held separately: the rollback below expires `source`, and re-reading
        # `.id` off it would emit lazy sync IO.
        qid = source.id
        session.add(_translation(qid, "sk"))
        await session.commit()

        session.add(_translation(qid, "sk"))
        with pytest.raises(IntegrityError):
            await session.commit()
        await session.rollback()

        # A *different* language is a different row, not a conflict.
        session.add(_translation(qid, "cs"))
        await session.commit()
        rows = (
            (
                await session.execute(
                    select(QuestionTranslation).where(
                        QuestionTranslation.question_id == qid
                    )
                )
            )
            .scalars()
            .all()
        )
        assert sorted(r.language for r in rows) == ["cs", "sk"]


async def test_deleting_the_question_cascades_to_translations_and_corrections(
    session: AsyncSession,
) -> None:
    """Delete-then-reimport must not strand a translation of deleted text.

    That workflow is how English corrections reach production; the cascade is
    what makes it safe by construction instead of needing a reconcile pass.
    """
    async with seeded_question(session) as source:
        translation = _translation(source.id, "sk")
        session.add(translation)
        await session.commit()
        session.add(
            QuestionTranslationCorrection(
                id=uuid.uuid4(),
                translation_id=translation.id,
                field="question",
                before="červenú",
                after="červená",
                category="fluency/grammar",
                source="founder-review",
            )
        )
        await session.commit()

        await session.execute(delete(QuestionRow).where(QuestionRow.id == source.id))
        await session.commit()

        translations_left = await session.scalar(
            select(func.count())
            .select_from(QuestionTranslation)
            .where(QuestionTranslation.question_id == source.id)
        )
        corrections_left = await session.scalar(
            select(func.count())
            .select_from(QuestionTranslationCorrection)
            .where(QuestionTranslationCorrection.translation_id == translation.id)
        )
        assert translations_left == 0
        assert corrections_left == 0


async def test_a_new_question_is_approved_in_no_language(
    session: AsyncSession,
) -> None:
    """`approved_languages` defaults to empty, never NULL.

    This default is what lets the migration land ahead of the deploy: existing
    rows acquire the pre-migration truth, and a re-imported question can never
    inherit a stale language approval from the row it replaced.
    """
    async with seeded_question(session) as source:
        # refresh, not the identity-mapped instance: the value under test is
        # the server default, so it exists only once the database wrote the row.
        await session.refresh(source)
        assert source.approved_languages == []
