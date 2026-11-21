"""daily_usage.voice_answers: the free monthly voice allowance (2026-11-21)

Revision ID: 0024_voice_answers
Revises: 0023_daily_crew_removals
Create Date: 2026-11-21

Expand only: one column with a constant default (metadata-only on Postgres
11+, no table rewrite); nothing existing changes.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0024_voice_answers"
down_revision: Union[str, Sequence[str], None] = "0023_daily_crew_removals"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "daily_usage",
        sa.Column("voice_answers", sa.Integer(), nullable=False, server_default="0"),
    )


def downgrade() -> None:
    op.drop_column("daily_usage", "voice_answers")
