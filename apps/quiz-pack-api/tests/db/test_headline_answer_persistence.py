"""`questions.headline_answer` must survive persistence (#133 V7).

WHY this matters, not just what it does: open/lateral questions carry two
answers — the long resolution in ``correct_answer`` and the short gettable gist
in ``headline_answer``, which is the one ``AnswerEvaluator`` scores against
(``headline_answer or correct_answer``) and the one the reveal reads. The column
did not exist, so ``question_to_row`` silently dropped every gist: a question
generated with BOTH fields was played and graded against its long resolution,
and the player could never say the answer the question was written around.

A fallback hid the single-answer case (``Question.from_dict`` mirrors the gist
into ``correct_answer`` when the open prompt complies with
``correct_answer: null``), which is why this went unnoticed — and why old rows
carrying NULL here are correct rather than broken.

Runs against the dev-stack Postgres (``TEST_DATABASE_URL``); the migration test
builds its own throwaway database so it can start from the *previous* revision.
"""

from __future__ import annotations

import os
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine

from quiz_shared.models.question import Question

from app.db.engine import normalize_async_url
from app.db.models import QuestionRow, question_to_row, row_to_question

APP_ROOT = Path(__file__).resolve().parents[2]

# The revision this column arrives in, and the one before it.
HEAD_REVISION = "b4d9e17c3a52"
PREVIOUS_REVISION = "a3f7c81d92be"

# A real open-shape pair: the long resolution belongs in `correct_answer`, the
# gettable gist in `headline_answer`. This is the shape that lost data — the
# `correct_answer: null` shape was already covered by the from_dict fallback.
LONG_RESOLUTION = (
    "Red was the international motor-racing colour assigned to Italy by the "
    "Automobile Club de France in the early 1900s, and Ferrari kept it after "
    "national racing colours were abandoned."
)
SHORT_GIST = "Italy's national racing colour"


def _raw_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    return url


def _alembic(*args: str, database_url: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["DATABASE_URL"] = database_url
    return subprocess.run(
        [sys.executable, "-m", "alembic", *args],
        cwd=APP_ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )


@pytest.fixture(scope="module", autouse=True)
def _alembic_head() -> None:
    """Bring the shared test DB to head so the new column exists."""
    _alembic("upgrade", "head", database_url=_raw_url())


def _open_question() -> Question:
    return Question(
        id=str(uuid.uuid4()),
        question="Why are Ferraris red?",
        type="text",
        correct_answer=LONG_RESOLUTION,
        headline_answer=SHORT_GIST,
        topic="Cars",
        category="adults",
        difficulty="medium",
        explanation=LONG_RESOLUTION,
        created_at=datetime(2026, 7, 30, 12, 0, tzinfo=timezone.utc),
    )


@pytest.mark.asyncio
async def test_open_question_keeps_both_answers_through_the_seam(
    session: AsyncSession,
) -> None:
    """A question with BOTH answers must read back with BOTH — the gist is not
    derivable from the long resolution, so dropping it is unrecoverable loss."""
    q = _open_question()
    row = question_to_row(q)
    session.add(row)
    await session.commit()
    try:
        fetched = await session.get(QuestionRow, row.id)
        assert fetched is not None
        assert fetched.headline_answer == SHORT_GIST

        back = row_to_question(fetched)
        assert back.headline_answer == SHORT_GIST
        # And the long resolution is untouched: the two answers are distinct
        # fields, not one field the gist overwrites.
        assert back.correct_answer == LONG_RESOLUTION
    finally:
        await session.execute(
            text("DELETE FROM questions WHERE id = :id"), {"id": row.id}
        )
        await session.commit()


@pytest.mark.asyncio
async def test_closed_question_stores_no_gist(session: AsyncSession) -> None:
    """Closed questions must stay NULL — same shape old rows keep, so the
    `from_dict` gist→correct_answer fallback still governs them."""
    q = Question(
        id=str(uuid.uuid4()),
        question="What is the capital of France?",
        correct_answer="Paris",
        topic="Geography",
        category="adults",
        difficulty="easy",
        created_at=datetime(2026, 7, 30, 12, 0, tzinfo=timezone.utc),
    )
    row = question_to_row(q)
    session.add(row)
    await session.commit()
    try:
        fetched = await session.get(QuestionRow, row.id)
        assert fetched is not None and fetched.headline_answer is None
        assert row_to_question(fetched).headline_answer is None
    finally:
        await session.execute(
            text("DELETE FROM questions WHERE id = :id"), {"id": row.id}
        )
        await session.commit()


@pytest.mark.asyncio
async def test_migration_adds_nullable_column_and_leaves_old_rows_null() -> None:
    """Upgrade a throwaway DB stopped at the previous revision.

    Starting at head would prove nothing about the migration; the point is that
    a database with pre-existing question rows gains the column without a
    rewrite and without inventing gists for rows that never had one.
    """
    raw = _raw_url()
    scratch_db = f"quiz_pack_migr_{uuid.uuid4().hex[:8]}"
    admin = create_async_engine(
        normalize_async_url(raw), isolation_level="AUTOCOMMIT"
    )
    scratch_url = raw.rsplit("/", 1)[0] + "/" + scratch_db
    try:
        async with admin.connect() as conn:
            await conn.execute(text(f'CREATE DATABASE "{scratch_db}"'))

        _alembic("upgrade", PREVIOUS_REVISION, database_url=scratch_url)

        scratch = create_async_engine(normalize_async_url(scratch_url))
        try:
            # Premise guard + an "old" row written before the column existed.
            old_id = uuid.uuid4()
            async with scratch.begin() as conn:
                cols = await conn.execute(
                    text(
                        "SELECT 1 FROM information_schema.columns "
                        "WHERE table_name = 'questions' "
                        "AND column_name = 'headline_answer'"
                    )
                )
                assert cols.first() is None, "column already present at prev revision"
                await conn.execute(
                    text(
                        "INSERT INTO questions (id, question, type, correct_answer, "
                        "topic, category, difficulty, source, review_status) "
                        "VALUES (:id, 'Old row', 'text', '\"Paris\"'::jsonb, "
                        "'Geography', 'adults', 'easy', 'generated', 'approved')"
                    ),
                    {"id": old_id},
                )

            _alembic("upgrade", "head", database_url=scratch_url)

            async with scratch.begin() as conn:
                meta = await conn.execute(
                    text(
                        "SELECT data_type, is_nullable FROM information_schema.columns "
                        "WHERE table_name = 'questions' "
                        "AND column_name = 'headline_answer'"
                    )
                )
                assert meta.first() == ("text", "YES")

                stayed_null = await conn.execute(
                    text("SELECT headline_answer FROM questions WHERE id = :id"),
                    {"id": old_id},
                )
                assert stayed_null.scalar_one() is None
        finally:
            await scratch.dispose()
    finally:
        async with admin.connect() as conn:
            await conn.execute(
                text(f'DROP DATABASE IF EXISTS "{scratch_db}" WITH (FORCE)')
            )
        await admin.dispose()
