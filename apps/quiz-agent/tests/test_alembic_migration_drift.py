"""Alembic model/migration drift guard (backend arch review 2026-07-18,
testability finding "divergent DB-fixture strategies; quiz-agent never
exercises migrations").

WHY this matters — not just what it does: every other DB-backed test in this
suite builds its schema from ``Base.metadata.create_all`` (see
``db_sessionmaker`` in conftest.py) — fast, but it means drift between the
ORM models and the actual Alembic migration history (revisions 0001..0006,
including the 0005 money/subscription migration) is invisible to the rest of
the suite. A model field added without a matching migration — or a migration
that diverges from the model — would pass every create_all-backed test today
and only surface as a runtime error against the real (migrated) production
database. This test closes that gap the other way: migrate a private scratch
database with the REAL Alembic history, then ask Alembic's own autogenerate
machinery (the same engine ``alembic revision --autogenerate`` uses) to diff
the migrated schema against ``Base.metadata``. A non-empty diff means the two
have drifted and a migration is missing.

Uses a dedicated scratch database (worktree concurrency rule — this suite
otherwise shares a persistent test DB with other agents' runs), created and
dropped around the test.
"""

from __future__ import annotations

import os
import subprocess
import sys
import uuid
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import asyncpg
import pytest
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from sqlalchemy.ext.asyncio import create_async_engine

from app.db.base import Base
from app.db.engine import normalize_async_url
import app.db.models  # noqa: F401 -- populate Base.metadata

pytestmark = pytest.mark.asyncio

APP_ROOT = Path(__file__).resolve().parents[1]  # apps/quiz-agent (holds alembic.ini)

# Mirrors alembic/env.py's VERSION_TABLE — the auth/usage migrations track
# their own state in a dedicated table so they coexist with quiz-pack-api's
# history in the same shared cluster (see test_alembic_version_table_isolation.py).
VERSION_TABLE = "alembic_version_quiz_agent"


def _server_url_and_scratch_name() -> tuple[str, str, str]:
    """Derive an admin (maintenance-db) URL and a unique scratch DB name from
    TEST_DATABASE_URL, per the worktree's private-scratch-DB concurrency rule."""
    raw = os.environ.get("TEST_DATABASE_URL")
    if not raw:
        pytest.skip("TEST_DATABASE_URL not set — skipping migration drift guard")
    parts = urlsplit(normalize_async_url(raw))
    dbname = f"quiz_agent_drift_{uuid.uuid4().hex[:10]}"
    admin_url = urlunsplit(parts._replace(path="/postgres"))
    scratch_url = urlunsplit(parts._replace(path=f"/{dbname}"))
    return admin_url, scratch_url, dbname


def _compare_sync(sync_conn) -> list:
    """Run inside ``AsyncConnection.run_sync`` — Alembic's comparison API is
    sync-only. ``version_table`` tells MigrationContext which table tracks
    migration state so it's excluded from the diff (it's not part of
    ``Base.metadata`` — it's Alembic's own bookkeeping table)."""
    context = MigrationContext.configure(
        sync_conn, opts={"version_table": VERSION_TABLE}
    )
    return compare_metadata(context, Base.metadata)


async def test_migrated_schema_matches_orm_metadata() -> None:
    """`alembic upgrade head` on a fresh DB must produce EXACTLY Base.metadata.

    A non-empty diff means a model field/table/index/constraint was added (or
    changed) without a matching migration, or a migration diverges from the
    model — the exact drift class create_all-backed tests can never catch
    (they build schema FROM the models, never from the migrations).
    """
    admin_url, scratch_url, dbname = _server_url_and_scratch_name()
    admin_dsn = admin_url.replace("postgresql+asyncpg://", "postgresql://", 1)

    conn = await asyncpg.connect(admin_dsn)
    try:
        await conn.execute(f'CREATE DATABASE "{dbname}"')
    finally:
        await conn.close()

    try:
        result = subprocess.run(
            [sys.executable, "-m", "alembic", "upgrade", "head"],
            cwd=APP_ROOT,
            env={**os.environ, "DATABASE_URL": scratch_url},
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"alembic upgrade head failed on scratch DB:\n{result.stderr}"
        )

        engine = create_async_engine(normalize_async_url(scratch_url))
        try:
            async with engine.connect() as db_conn:
                diff = await db_conn.run_sync(_compare_sync)
        finally:
            await engine.dispose()

        assert diff == [], (
            "Alembic migration history has drifted from Base.metadata — "
            f"autogenerate would emit: {diff}. Add a migration to close the "
            "gap (models.py and the migrations must describe the same schema)."
        )
    finally:
        conn = await asyncpg.connect(admin_dsn)
        try:
            # Drop any lingering connections first (the migrated engine above
            # is disposed, but a stray one would make DROP DATABASE hang).
            await conn.execute(
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                "WHERE datname = $1 AND pid <> pg_backend_pid()",
                dbname,
            )
            await conn.execute(f'DROP DATABASE IF EXISTS "{dbname}"')
        finally:
            await conn.close()
