"""init: empty baseline (issue #33 task 1.3)

Enables the pgvector extension on a fresh DB so `alembic upgrade head` alone is
enough to bootstrap any environment (CI, test, prod) — independent of the local
docker-compose `db/init/` script.

Forward-only per issue-33 R8: do not implement `downgrade()` for prod migrations.

Revision ID: 29f509ffa769
Revises:
Create Date: 2026-05-07 15:51:26.046416
"""

from typing import Sequence, Union

from alembic import op

revision: str = "29f509ffa769"
down_revision: Union[str, Sequence[str], None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS vector")


def downgrade() -> None:
    pass
