"""Shared pytest fixtures for quiz-agent (issue #60 auth DB tests).

Async DB fixtures target ``TEST_DATABASE_URL`` (a throwaway Postgres) so the dev
/ prod DB is never touched. If no test DB is configured, the DB-backed tests
skip rather than fail — the pure-unit suites (e.g. token tests) still run
everywhere. Set ``REQUIRE_DB_TESTS=1`` to turn that skip into a failure (see
``require_db_url``).
"""

from __future__ import annotations

import os
import socket
from pathlib import Path
from typing import AsyncIterator
from urllib.parse import urlsplit

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


_REACHABLE: dict[str, bool] = {}


def _is_reachable(url: str) -> bool:
    """Whether something is listening on the URL's host:port (cached per URL)."""
    if url in _REACHABLE:
        return _REACHABLE[url]
    parts = urlsplit(url)
    if not parts.hostname:  # unix socket / unparseable — let the driver decide
        _REACHABLE[url] = True
        return True
    try:
        with socket.create_connection((parts.hostname, parts.port or 5432), timeout=3):
            _REACHABLE[url] = True
    except OSError:
        _REACHABLE[url] = False
    return _REACHABLE[url]


def require_db_url(purpose: str = "DB-backed test") -> str:
    """The test Postgres URL, or a stop — skipped by default, LOUD on demand.

    One place decides skip-vs-fail for every DB-backed suite (``db_sessionmaker``
    below, ``tests/db/*``, the question monitor, the migration-drift guard).
    Those four suites each carried their own ``pytest.skip("TEST_DATABASE_URL
    not set")``, so a run with no database reported green while the whole
    DB-backed half of the suite quietly never executed — including the
    pack-ownership IDOR gate and the alembic drift guard.

    ``REQUIRE_DB_TESTS=1`` (CI, pre-release, any run whose green must mean
    something) turns a missing URL *or* a host nothing is listening on into a
    FAILURE. Without it the default stays a skip, so the pure-unit suites still
    run on a laptop with no Postgres. A URL that connects but is otherwise wrong
    (missing database, bad credentials) raises a driver error in both modes —
    nothing here converts that into a skip.
    """
    url = _test_db_url()
    required = os.environ.get("REQUIRE_DB_TESTS") == "1"

    if not url:
        if required:
            pytest.fail(
                f"REQUIRE_DB_TESTS=1 but TEST_DATABASE_URL is not set — {purpose} "
                "must run, not skip"
            )
        pytest.skip(f"TEST_DATABASE_URL not set — skipping {purpose}")

    if required and not _is_reachable(url):
        parts = urlsplit(url)
        pytest.fail(
            f"REQUIRE_DB_TESTS=1 but no Postgres is listening on "
            f"{parts.hostname}:{parts.port or 5432} — {purpose} must run, not skip"
        )
    return url


@pytest_asyncio.fixture
async def db_sessionmaker() -> AsyncIterator[async_sessionmaker[AsyncSession]]:
    """Fresh schema per test (drop+create) on the test Postgres, then dispose."""
    url = require_db_url("auth/usage DB fixtures")

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
