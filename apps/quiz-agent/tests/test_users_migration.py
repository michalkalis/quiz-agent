"""Migration guard for the ``users`` table (issue #61, task 61.1).

Runs Alembic in offline (``--sql``) mode like
``test_alembic_version_table_isolation`` — no live Postgres needed — and asserts
the generated DDL matches the F1/F5/F8 schema and that the downgrade is a clean
inverse. A live ``upgrade head``/``downgrade`` round-trip on a scratch DB is run
separately at delivery; this test keeps the contract green in CI.
"""

import os
import subprocess
import sys
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parents[1]  # apps/quiz-agent (holds alembic.ini)


def _offline_sql(*alembic_args: str) -> str:
    """SQL that ``alembic <args> --sql`` emits with a dummy URL (offline mode
    never connects — and the dummy URL stops a stray real DATABASE_URL in the
    shell from pointing the test at a live cluster)."""
    result = subprocess.run(
        [sys.executable, "-m", "alembic", *alembic_args, "--sql"],
        cwd=APP_ROOT,
        env={
            **os.environ,
            "DATABASE_URL": "postgresql+asyncpg://dummy:dummy@localhost/dummy",
        },
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"alembic offline run failed:\n{result.stderr}"
    return result.stdout


def test_upgrade_creates_users_with_the_f1_f5_f8_schema():
    sql = _offline_sql("upgrade", "0002_app_attest:0003_users")
    assert "CREATE TABLE users" in sql
    # apple_sub is the durable account anchor and must be UNIQUE NOT NULL.
    assert "apple_sub TEXT NOT NULL" in sql
    assert "UNIQUE (apple_sub)" in sql
    # F5 (store Apple name) and F1/F2 (encrypted-at-rest refresh token, BYTEA).
    assert "full_name TEXT" in sql
    assert "apple_refresh_token_encrypted BYTEA" in sql
    # PK is a UUID, created_at is timezone-aware.
    assert "id UUID NOT NULL" in sql
    assert "created_at TIMESTAMP WITH TIME ZONE NOT NULL" in sql
    # F8: subscriptions deferred — no plan_tier column.
    assert "plan_tier" not in sql


def test_downgrade_drops_users():
    sql = _offline_sql("downgrade", "0003_users:0002_app_attest")
    assert "DROP TABLE users" in sql


def test_users_migration_uses_the_isolated_version_table():
    """0003 must track state in the dedicated table, never quiz-pack's shared
    default ``alembic_version`` (the same contract the phase-1 migrations hold)."""
    sql = _offline_sql("upgrade", "0002_app_attest:0003_users")
    assert "alembic_version_quiz_agent" in sql
    without_dedicated = sql.replace("alembic_version_quiz_agent", "")
    assert "alembic_version" not in without_dedicated
