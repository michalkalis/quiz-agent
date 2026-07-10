"""Async DB smoke + alembic-upgrade-head idempotency (issue #33 Task 1.3)."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.engine import normalize_async_url

APP_ROOT = Path(__file__).resolve().parents[2]


def test_normalize_async_url_rewrites_libpq() -> None:
    assert (
        normalize_async_url("postgres://u:p@h:5432/db")
        == "postgresql+asyncpg://u:p@h:5432/db"
    )
    assert (
        normalize_async_url("postgresql://u:p@h:5432/db")
        == "postgresql+asyncpg://u:p@h:5432/db"
    )
    assert (
        normalize_async_url("postgresql+asyncpg://u:p@h:5432/db")
        == "postgresql+asyncpg://u:p@h:5432/db"
    )


@pytest.mark.asyncio
async def test_session_select_one(session: AsyncSession) -> None:
    result = await session.execute(text("SELECT 1"))
    assert result.scalar_one() == 1


@pytest.mark.asyncio
async def test_pgvector_extension_present(session: AsyncSession) -> None:
    result = await session.execute(
        text("SELECT extname FROM pg_extension WHERE extname = 'vector'")
    )
    assert result.scalar_one_or_none() == "vector"


def test_alembic_upgrade_head_is_idempotent() -> None:
    """Running upgrade head twice on a populated DB must be a no-op the second time."""
    env = os.environ.copy()
    test_url = env.get("TEST_DATABASE_URL") or env.get("DATABASE_URL")
    if not test_url:
        pytest.skip("TEST_DATABASE_URL/DATABASE_URL not set")
    env["DATABASE_URL"] = test_url

    def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            cmd,
            cwd=APP_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=True,
        )

    alembic = [sys.executable, "-m", "alembic"]
    first = run(alembic + ["upgrade", "head"])
    second = run(alembic + ["upgrade", "head"])
    current = run(alembic + ["current"])

    # Second run should not log "Running upgrade" — there's nothing left to apply.
    assert "Running upgrade" not in second.stderr
    assert "Running upgrade" not in second.stdout
    # And current revision should match head.
    assert "7a2c91d40b1e" in (current.stdout + current.stderr)
    # First run is allowed to be a no-op too (DB may already be at head from a
    # prior pytest invocation), so we don't assert on it — its purpose is only
    # to guarantee the DB is at head before the second-run idempotency check.
    _ = first
