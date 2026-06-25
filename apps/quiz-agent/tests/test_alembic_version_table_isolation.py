"""Regression test: the auth/usage migrations must track their state in a
DEDICATED Alembic version table, never the default ``alembic_version``
(issue #60 decision #2 — auth tables co-locate in the shared ``quiz-pack-db``).

WHY this matters -- not just what it does: ``DATABASE_URL`` is a single secret
that drives BOTH the #36 voice read-path (which reads ``questions``) and the #60
auth/usage tables, so both must live in the SAME database -- the existing
``quiz_pack`` DB, which quiz-pack-api already migrates with the DEFAULT
``alembic_version`` table (head ``1c5e0fa7b3d4``). Two independent Alembic
histories cannot share one version table: if these migrations used the default,
Alembic would read quiz-pack's revision out of ``alembic_version``, fail to find
it in this app's script directory, and abort ``upgrade head`` -- the auth tables
would never be created (or worse, quiz-pack's migration state would be
clobbered). The contract pinned here: this app's migrations write ONLY to
``alembic_version_quiz_agent`` and leave the default table untouched, so the two
histories coexist safely in one database.

Runs Alembic in offline (``--sql``) mode, so it needs NO live Postgres -- it
asserts on the generated DDL/DML, which is exactly what an in-container
``alembic upgrade head`` would execute against ``quiz-pack-db``.
"""

import os
import subprocess
import sys
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parents[1]  # apps/quiz-agent (holds alembic.ini)


def _offline_upgrade_sql() -> str:
    """The SQL `alembic upgrade head --sql` emits, with a dummy URL (offline
    mode never connects). Mirrors the in-container migration the flip runs."""
    result = subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head", "--sql"],
        cwd=APP_ROOT,
        # Inherit the real env (HOME/PATH/venv) but force a dummy URL: offline
        # mode never connects, and this guarantees a stray real DATABASE_URL in
        # the dev shell can't point the test at a live cluster.
        env={
            **os.environ,
            "DATABASE_URL": "postgresql+asyncpg://dummy:dummy@localhost/dummy",
        },
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"alembic offline run failed:\n{result.stderr}"
    return result.stdout


def test_migrations_use_isolated_version_table_not_the_shared_default():
    sql = _offline_upgrade_sql()

    # State is tracked in the dedicated table...
    assert "alembic_version_quiz_agent" in sql
    assert "CREATE TABLE alembic_version_quiz_agent" in sql

    # ...and the default table quiz-pack-db already owns is never written. Strip
    # the dedicated table's name first so its substring doesn't yield a false
    # positive for the bare default.
    without_dedicated = sql.replace("alembic_version_quiz_agent", "")
    assert "alembic_version" not in without_dedicated, (
        "migrations referenced the DEFAULT alembic_version table -- this would "
        "collide with quiz-pack-api's history in the shared quiz_pack database"
    )


def test_offline_upgrade_creates_all_five_auth_tables():
    """Guards that the version-table change didn't silently drop the actual
    schema: the flip is worthless if these tables aren't created."""
    sql = _offline_upgrade_sql()
    for table in (
        "anonymous_identities",
        "refresh_tokens",
        "daily_usage",
        "attest_challenges",
        "app_attest_keys",
    ):
        assert f"CREATE TABLE {table}" in sql, f"missing CREATE TABLE {table}"
