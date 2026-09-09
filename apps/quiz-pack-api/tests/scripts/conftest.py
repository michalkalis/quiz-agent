"""DB fixtures for the #168 runner tests — the same test-DB + alembic-head
pattern as ``tests/db/test_translation_staleness.py`` (skips without a URL)."""

from __future__ import annotations

import os
import subprocess
import sys
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from pathlib import Path

import pytest
import pytest_asyncio
from app.db.engine import build_engine, normalize_async_url
from quiz_shared.database.pgvector_client import EMBEDDING_DIM, PgvectorQuestionStore
from quiz_shared.models.question import Question
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

APP_ROOT = Path(__file__).resolve().parents[2]


def _raw_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    return url


@pytest.fixture(scope="module")
def _alembic_head() -> None:
    env = os.environ.copy()
    env["DATABASE_URL"] = _raw_url()
    subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        cwd=APP_ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )


@pytest_asyncio.fixture
async def translation_engine(_alembic_head) -> AsyncIterator[AsyncEngine]:
    eng = build_engine(normalize_async_url(_raw_url()))
    try:
        yield eng
    finally:
        await eng.dispose()


@pytest_asyncio.fixture
async def question_store(translation_engine: AsyncEngine) -> PgvectorQuestionStore:
    factory = async_sessionmaker(
        translation_engine, class_=AsyncSession, expire_on_commit=False
    )
    return PgvectorQuestionStore(
        session_factory=factory, embedder=lambda _t: [0.0] * EMBEDDING_DIM
    )


def make_question(
    qid: uuid.UUID,
    *,
    category: str = "history",
    difficulty: str = "medium",
    review_status: str = "approved",
    possible_answers: dict[str, str] | None = None,
    correct_answer: str = "Italy",
) -> Question:
    return Question(
        id=str(qid),
        question="Which country raced in rosso corsa?",
        type="text_multichoice" if possible_answers else "text",
        possible_answers=possible_answers,
        correct_answer=correct_answer,
        alternative_answers=["Italia"],
        explanation="Rosso corsa was Italy's national racing colour.",
        topic="motorsport",
        category=category,
        difficulty=difficulty,
        review_status=review_status,
        source="generated",
        embedding=[0.0] * EMBEDDING_DIM,
        embedding_model="test-fixture",
        embedding_dim=EMBEDDING_DIM,
        created_at=datetime.now(UTC),
    )


async def delete_questions(engine: AsyncEngine, qids: list[uuid.UUID]) -> None:
    """Cascade drops the translation rows with the questions."""
    async with engine.begin() as conn:
        for qid in qids:
            await conn.execute(
                text("DELETE FROM questions WHERE id = :qid"), {"qid": qid}
            )
