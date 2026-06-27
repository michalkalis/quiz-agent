"""Migration guard for refresh_tokens subject generalisation (issue #61, 61.4).

Runs Alembic offline (``--sql``) like ``test_users_migration`` — no live Postgres
— and asserts 0004 drops the anon-only FK so a refresh token's subject can be a
``users.id`` (Sign in with Apple), and that the downgrade re-adds it as a clean
inverse.
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


def test_upgrade_drops_the_anon_only_foreign_key():
    sql = _offline_sql("upgrade", "0003_users:0004_refresh_subject")
    assert (
        "ALTER TABLE refresh_tokens DROP CONSTRAINT refresh_tokens_anon_id_fkey" in sql
    )


def test_downgrade_readds_the_foreign_key():
    sql = _offline_sql("downgrade", "0004_refresh_subject:0003_users")
    assert "ADD CONSTRAINT refresh_tokens_anon_id_fkey FOREIGN KEY" in sql
    assert "anonymous_identities" in sql
