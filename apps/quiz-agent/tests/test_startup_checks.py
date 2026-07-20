"""Tests for startup_checks: warn_if_insecure_production.

(`verify_chroma_path_on_volume` was retired with the ChromaDB decommission,
#41 D7 — pgvector has no on-volume path to verify.)
"""

from __future__ import annotations

import logging
from types import SimpleNamespace

import pytest

from app import startup_checks
from app.startup_checks import assert_migrations_at_head, warn_if_insecure_production


# ── warn_if_insecure_production (#65) ────────────────────────────────────────


def _settings(required: bool, app_id: str | None = None) -> SimpleNamespace:
    return SimpleNamespace(app_attest_required=required, app_attest_app_id=app_id)


def _security_errors(records: list[logging.LogRecord]) -> list[str]:
    return [
        r.getMessage()
        for r in records
        if r.levelno == logging.ERROR and "SECURITY" in r.getMessage()
    ]


def test_warn_prod_app_attest_inert_logs_error(caplog) -> None:
    """Prod with App Attest off → a loud SECURITY error (does not raise)."""
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(_settings(required=False), "production", logger)
    errors = _security_errors(caplog.records)
    assert errors and "INERT" in errors[0]


def test_warn_development_is_silent(caplog) -> None:
    """Non-prod boots never warn, even with App Attest off."""
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(_settings(required=False), "development", logger)
    assert _security_errors(caplog.records) == []


def test_warn_prod_required_but_no_app_id_logs_error(caplog) -> None:
    """Required-on but APP_ATTEST_APP_ID unset → the second loud error path."""
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(
            _settings(required=True, app_id=None), "production", logger
        )
    errors = _security_errors(caplog.records)
    assert errors and "APP_ATTEST_APP_ID" in errors[0]


def test_warn_prod_fully_configured_is_silent(caplog, monkeypatch) -> None:
    """Required-on with an app id and grace off → no warning."""
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(
            _settings(required=True, app_id="TEAMID.com.missinghue.hangs"),
            "production",
            logger,
        )
    assert _security_errors(caplog.records) == []


def test_warn_prod_grace_on_logs_error(caplog, monkeypatch) -> None:
    """Grace on in production → loud SECURITY error, even when App Attest is
    fully configured (#65 follow-up, founder decision #5 2026-07-05)."""
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "on")
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(
            _settings(required=True, app_id="TEAMID.com.missinghue.hangs"),
            "production",
            logger,
        )
    errors = _security_errors(caplog.records)
    assert errors and "LEGACY_USER_ID_GRACE" in errors[0]


def test_warn_development_grace_is_silent(caplog, monkeypatch) -> None:
    """Grace on outside production stays silent — it is the intended dev default."""
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "on")
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(
            _settings(required=True, app_id="x"), "development", logger
        )
    assert _security_errors(caplog.records) == []


# ── assert_migrations_at_head (backend arch review 2026-07-18) ───────────────
#
# Migrations are manual (migrate-before-deploy); this check is the fail-loud
# gate that a deploy against an unmigrated schema crashes at boot (Fly rolls
# back) instead of erroring at runtime. Script head comes from the REAL
# alembic/ directory; only the DB-side revision lookup is stubbed, so no
# Postgres is needed.

_LOGGER = logging.getLogger("test.startup_checks.migrations")


def _stub_db_revision(monkeypatch, revision: str | None) -> None:
    async def fake(_url: str) -> str | None:
        return revision

    monkeypatch.setattr(startup_checks, "_db_revision", fake)


def _real_head() -> str:
    heads = startup_checks._script_directory().get_heads()
    assert len(heads) == 1, f"expected a linear history, got heads {heads}"
    return heads[0]


@pytest.mark.asyncio
async def test_head_check_skips_silently_without_database_url(monkeypatch) -> None:
    """Dev boots without a DB must not be blocked — and must not touch one."""

    async def boom(_url: str) -> str | None:
        raise AssertionError("DB must not be queried when DATABASE_URL is unset")

    monkeypatch.setattr(startup_checks, "_db_revision", boom)
    await assert_migrations_at_head(None, _LOGGER)  # no raise


@pytest.mark.asyncio
async def test_head_check_passes_when_db_at_head(monkeypatch) -> None:
    _stub_db_revision(monkeypatch, _real_head())
    await assert_migrations_at_head("postgresql+asyncpg://x/x", _LOGGER)


@pytest.mark.asyncio
async def test_head_check_fails_loud_when_never_migrated(monkeypatch) -> None:
    """Missing/empty version table = schema absent → boot must fail, and the
    error must name the manual upgrade command (there is no auto-migrate)."""
    _stub_db_revision(monkeypatch, None)
    with pytest.raises(RuntimeError, match="alembic upgrade head"):
        await assert_migrations_at_head("postgresql+asyncpg://x/x", _LOGGER)


@pytest.mark.asyncio
async def test_head_check_fails_loud_when_db_behind(monkeypatch) -> None:
    """DB on an older known revision → the deploy shipped unapplied
    migrations; boot must fail so Fly rolls the deploy back."""
    revisions = [
        r.revision for r in startup_checks._script_directory().walk_revisions()
    ]
    oldest = revisions[-1]
    assert oldest != _real_head()
    _stub_db_revision(monkeypatch, oldest)
    with pytest.raises(RuntimeError, match="BEHIND"):
        await assert_migrations_at_head("postgresql+asyncpg://x/x", _LOGGER)


@pytest.mark.asyncio
async def test_head_check_passes_when_db_ahead_of_code(monkeypatch) -> None:
    """A revision this build doesn't know = DB migrated before the deploy
    rolled out — the intended migrate-before-deploy order must NOT block."""
    _stub_db_revision(monkeypatch, "deadbeef1234")
    await assert_migrations_at_head("postgresql+asyncpg://x/x", _LOGGER)
