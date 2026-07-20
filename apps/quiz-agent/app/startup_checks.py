"""Startup invariants that must hold before the API begins serving traffic.

Each check raises a clear `RuntimeError` on failure. Failures crash the worker
during Fly's health-check grace period so the deploy rolls back cleanly.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any


def warn_if_insecure_production(
    settings: Any, environment: str | None, logger: logging.Logger
) -> None:
    """Log loudly when prod ships with App Attest effectively disabled (#65).

    App Attest defaults to inert (``app_attest_required=False``), so the whole
    #60 attestation investment ships off unless a Fly secret turns it on. We
    log an error rather than refuse to boot — a hard boot-fail on a misconfig
    could take down prod, whereas a loud ``logger.error`` in the deploy logs
    surfaces it without that risk. Logger is injected so this is unit-testable.

    Only fires in production; development/test boots are silent.
    """
    if environment != "production":
        return
    if not settings.app_attest_required:
        logger.error(
            "SECURITY: App Attest is INERT in production (APP_ATTEST_REQUIRED is "
            "off). Anonymous bootstrap will mint identities without device "
            "attestation. Set APP_ATTEST_REQUIRED=on and APP_ATTEST_APP_ID to "
            "enforce it (#60 Part B)."
        )
    elif not settings.app_attest_app_id:
        logger.error(
            "SECURITY: APP_ATTEST_REQUIRED is on but APP_ATTEST_APP_ID is unset — "
            "attestation cannot be verified. Set APP_ATTEST_APP_ID "
            "('<TeamID>.<BundleID>') to enforce App Attest (#60 Part B)."
        )

    from .auth.identity import legacy_grace_enabled

    if legacy_grace_enabled():
        logger.error(
            "SECURITY: LEGACY_USER_ID_GRACE is ON in production — requests "
            "without a bearer token pass unauthenticated through the auth gate "
            "(each pass is logged as 'AUTH GRACE'). Flip LEGACY_USER_ID_GRACE=off "
            "once all live clients send bearers (#65, founder decision #5)."
        )


# ── Migration head check (backend arch review 2026-07-18) ────────────────────

# Must match alembic/env.py: quiz-agent tracks its own Alembic history in a
# dedicated version table because it co-tenants the shared quiz-pack-db
# cluster, whose default `alembic_version` table quiz-pack-api owns.
VERSION_TABLE = "alembic_version_quiz_agent"

_APP_ROOT = Path(__file__).resolve().parents[1]  # apps/quiz-agent (alembic.ini)

_UPGRADE_CMD = (
    "cd apps/quiz-agent && python -m alembic upgrade head (prod: via `fly ssh console`)"
)


def _script_directory():
    """This build's Alembic script directory (needs alembic/ + alembic.ini,
    both shipped in the Docker image via the whole-app COPY)."""
    from alembic.config import Config
    from alembic.script import ScriptDirectory

    return ScriptDirectory.from_config(Config(str(_APP_ROOT / "alembic.ini")))


async def _db_revision(database_url: str) -> str | None:
    """Revision recorded in this app's own version table; ``None`` when the
    table is missing or empty (migrations never ran on this database)."""
    from sqlalchemy import text
    from sqlalchemy.exc import ProgrammingError

    from .db.engine import build_engine

    engine = build_engine(database_url)
    try:
        async with engine.connect() as conn:
            try:
                result = await conn.execute(
                    text(f"SELECT version_num FROM {VERSION_TABLE}")
                )
            except ProgrammingError:  # UndefinedTable — never migrated
                return None
            row = result.first()
        return row[0] if row else None
    finally:
        await engine.dispose()


async def assert_migrations_at_head(
    database_url: str | None, logger: logging.Logger
) -> None:
    """Refuse to boot when the DB schema is behind this build's migration head.

    Migrations stay MANUAL (founder policy — no ``release_command``); the
    discipline is migrate-before-deploy. This check makes a forgotten upgrade
    fail loud at boot instead of surfacing as runtime errors on an unmigrated
    schema: the raise crashes the worker during Fly's health-check grace
    period and the deploy rolls back cleanly.

    - no ``DATABASE_URL`` (dev boot without a DB) → skip silently
    - DB at this build's head → pass
    - DB at a revision this build doesn't know → PASS: the DB was migrated
      ahead of the deploy, which is exactly the migrate-before-deploy order
    - version table missing/empty, or DB on an older known revision → raise,
      naming the manual upgrade command
    """
    if not database_url:
        return

    script = _script_directory()
    heads = script.get_heads()
    db_rev = await _db_revision(database_url)

    if db_rev in heads:
        logger.info("Migrations at head (%s) — OK", db_rev)
        return
    if db_rev is None:
        raise RuntimeError(
            f"Database has no '{VERSION_TABLE}' migration state — quiz-agent "
            "migrations never ran on this database. Migrations are manual: "
            f"run `{_UPGRADE_CMD}` against this DATABASE_URL, then redeploy."
        )

    from alembic.util.exc import CommandError

    try:
        script.get_revision(db_rev)
    except CommandError:
        # Revision unknown to this build → DB is AHEAD (migrated before this
        # deploy rolled out). That is the intended order; don't block boot.
        logger.info(
            "DB migration revision %s is ahead of code head %s — OK "
            "(migrate-before-deploy)",
            db_rev,
            heads,
        )
        return
    raise RuntimeError(
        f"Database schema is BEHIND this build: DB at revision {db_rev}, "
        f"code head {heads}. Migrations are manual — run `{_UPGRADE_CMD}` "
        "before deploying this build."
    )
