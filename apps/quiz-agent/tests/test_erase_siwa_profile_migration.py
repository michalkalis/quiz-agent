"""Migration guard for 0009 (erase stored Sign in with Apple email/name).

Offline (``--sql``) like ``test_users_migration`` — no live Postgres. Founder
decision 2026-10-07 (GDPR data minimisation): existing email/full_name must be
wiped on deploy, and the migration must not touch the schema (the columns stay).
"""

import os
import subprocess
import sys
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parents[1]  # apps/quiz-agent (holds alembic.ini)


def _offline_sql(*alembic_args: str) -> str:
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


def test_upgrade_nulls_both_columns_for_every_user_without_schema_change():
    sql = _offline_sql("upgrade", "0008_analytics_events:0009_erase_siwa_profile")
    # No WHERE: every stored email/name is personal data nobody uses.
    assert "UPDATE users SET email = NULL, full_name = NULL" in sql
    # Data-only: dropping the columns would break the drift guard and old rows.
    assert "ALTER TABLE" not in sql
    assert "DROP COLUMN" not in sql


def test_downgrade_is_a_noop_because_erased_data_cannot_be_restored():
    sql = _offline_sql("downgrade", "0009_erase_siwa_profile:0008_analytics_events")
    assert "UPDATE users" not in sql
