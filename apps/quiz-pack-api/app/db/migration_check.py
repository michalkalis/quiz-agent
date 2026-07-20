"""Boot-time migration head check (backend arch review 2026-07-18).

Same semantics as quiz-agent's ``startup_checks.assert_migrations_at_head``:
migrations stay MANUAL (founder policy — no ``release_command``); the
discipline is migrate-before-deploy, and this check makes a forgotten
``alembic upgrade head`` fail loud at boot instead of surfacing as runtime
errors on an unmigrated schema. A raise during startup crashes the machine
inside Fly's health-check grace period, so the deploy rolls back cleanly.

Wired into both ``app/main.py`` (API lifespan) and ``app/worker/worker.py``
(``on_startup``) — separate processes, one call each. This module still has
no import-time side effects.
"""

from __future__ import annotations

import logging
from pathlib import Path

# quiz-pack-api owns the DEFAULT version table in the shared cluster;
# quiz-agent's co-tenant history lives in `alembic_version_quiz_agent`.
VERSION_TABLE = "alembic_version"

_APP_ROOT = Path(__file__).resolve().parents[2]  # apps/quiz-pack-api (alembic.ini)

_UPGRADE_CMD = (
    "cd apps/quiz-pack-api && python -m alembic upgrade head "
    "(prod: via `fly ssh console`)"
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

    from .engine import build_engine

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

    - no ``database_url`` → skip silently (dev boot without a DB)
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
            f"Database has no '{VERSION_TABLE}' migration state — "
            "quiz-pack-api migrations never ran on this database. Migrations "
            f"are manual: run `{_UPGRADE_CMD}` against this DATABASE_URL, "
            "then redeploy."
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
