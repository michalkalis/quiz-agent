"""Boot-time migration head check (backend arch review 2026-07-18).

Migrations are manual (migrate-before-deploy, founder policy — no
``release_command``); ``assert_migrations_at_head`` is the fail-loud gate
that a deploy against an unmigrated schema crashes at boot (Fly rolls back)
instead of erroring at runtime. Script head comes from the REAL alembic/
directory; only the DB-side revision lookup is stubbed, so no Postgres is
needed. (The check is not yet wired into main.py/worker — a follow-up owns
that; these tests pin the semantics the wiring will rely on.)
"""

from __future__ import annotations

import logging

import pytest

from app.db import migration_check
from app.db.migration_check import assert_migrations_at_head

_LOGGER = logging.getLogger("test.migration_check")


def _stub_db_revision(monkeypatch, revision: str | None) -> None:
    async def fake(_url: str) -> str | None:
        return revision

    monkeypatch.setattr(migration_check, "_db_revision", fake)


def _real_head() -> str:
    heads = migration_check._script_directory().get_heads()
    assert len(heads) == 1, f"expected a linear history, got heads {heads}"
    return heads[0]


async def test_head_check_skips_silently_without_database_url(monkeypatch) -> None:
    """Boots without a DB URL must not be blocked — and must not touch a DB."""

    async def boom(_url: str) -> str | None:
        raise AssertionError("DB must not be queried when database_url is unset")

    monkeypatch.setattr(migration_check, "_db_revision", boom)
    await assert_migrations_at_head(None, _LOGGER)  # no raise


async def test_head_check_passes_when_db_at_head(monkeypatch) -> None:
    _stub_db_revision(monkeypatch, _real_head())
    await assert_migrations_at_head("postgresql+asyncpg://x/x", _LOGGER)


async def test_head_check_fails_loud_when_never_migrated(monkeypatch) -> None:
    """Missing/empty version table = schema absent → boot must fail, and the
    error must name the manual upgrade command (there is no auto-migrate)."""
    _stub_db_revision(monkeypatch, None)
    with pytest.raises(RuntimeError, match="alembic upgrade head"):
        await assert_migrations_at_head("postgresql+asyncpg://x/x", _LOGGER)


async def test_head_check_fails_loud_when_db_behind(monkeypatch) -> None:
    """DB on an older known revision → the deploy shipped unapplied
    migrations; boot must fail so Fly rolls the deploy back."""
    revisions = [
        r.revision for r in migration_check._script_directory().walk_revisions()
    ]
    oldest = revisions[-1]
    assert oldest != _real_head()
    _stub_db_revision(monkeypatch, oldest)
    with pytest.raises(RuntimeError, match="BEHIND"):
        await assert_migrations_at_head("postgresql+asyncpg://x/x", _LOGGER)


async def test_head_check_passes_when_db_ahead_of_code(monkeypatch) -> None:
    """A revision this build doesn't know = DB migrated before the deploy
    rolled out — the intended migrate-before-deploy order must NOT block."""
    _stub_db_revision(monkeypatch, "deadbeef1234")
    await assert_migrations_at_head("postgresql+asyncpg://x/x", _LOGGER)
