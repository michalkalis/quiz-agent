"""app_switches: remote app switches without a restart (#207 task 207.18)

Revision ID: 0015_app_switches
Revises: 0014_usage_counters
Create Date: 2026-10-16

Expand only: a new table, nothing existing changes. Empty table = every
switch keeps its env value, exactly as before.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0015_app_switches"
down_revision: Union[str, Sequence[str], None] = "0014_usage_counters"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "app_switches",
        sa.Column("key", sa.Text(), primary_key=True),
        sa.Column("value", sa.Text(), nullable=True),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
    )


def downgrade() -> None:
    op.drop_table("app_switches")
