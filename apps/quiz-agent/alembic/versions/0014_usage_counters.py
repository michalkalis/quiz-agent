"""usage_counters: per-subject daily cost counters for abuse caps (#207 task 207.13)

Revision ID: 0014_usage_counters
Revises: 0013_daily_challenge
Create Date: 2026-10-16

Expand only: a new table, nothing existing changes.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0014_usage_counters"
down_revision: Union[str, Sequence[str], None] = "0013_daily_challenge"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "usage_counters",
        sa.Column("subject_id", sa.Text(), primary_key=True),
        sa.Column("usage_date", sa.Date(), primary_key=True),
        sa.Column("metric", sa.Text(), primary_key=True),
        sa.Column("amount", sa.BigInteger(), nullable=False, server_default="0"),
    )


def downgrade() -> None:
    op.drop_table("usage_counters")
