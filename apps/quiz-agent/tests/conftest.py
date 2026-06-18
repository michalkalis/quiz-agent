"""Shared pytest fixtures for quiz-agent (issue #60 auth DB tests).

Async DB fixtures target ``TEST_DATABASE_URL`` (a throwaway Postgres) so the dev
/ prod DB is never touched. If no test DB is configured, the DB-backed tests
skip rather than fail — the pure-unit suites (e.g. token tests) still run
everywhere.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import AsyncIterator

import pytest
import pytest_asyncio
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

try:
    from dotenv import load_dotenv

    repo_root = Path(__file__).resolve().parents[3]
    load_dotenv(repo_root / ".env", override=False)
except ImportError:
    pass

from app.db.base import Base  # noqa: E402
from app.db.engine import build_engine  # noqa: E402
import app.db.models  # noqa: E402,F401  -- populate Base.metadata


def _test_db_url() -> str | None:
    return os.environ.get("TEST_DATABASE_URL")


@pytest_asyncio.fixture
async def db_sessionmaker() -> AsyncIterator[async_sessionmaker[AsyncSession]]:
    """Fresh schema per test (drop+create) on the test Postgres, then dispose."""
    url = _test_db_url()
    if not url:
        pytest.skip("TEST_DATABASE_URL not set — skipping DB-backed test")

    engine = build_engine(url)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    try:
        yield async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    finally:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
        await engine.dispose()
