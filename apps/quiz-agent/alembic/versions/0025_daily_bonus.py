"""daily_challenge_plays bonus columns: the reward for finishing (#205, 205.8)

Revision ID: 0025_daily_bonus
Revises: 0024_voice_answers
Create Date: 2026-11-22

Expand only: a nullable column and one with a constant default (metadata-only
on Postgres 11+); old rows have no bonus and nothing existing changes.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0025_daily_bonus"
down_revision: Union[str, Sequence[str], None] = "0024_voice_answers"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "daily_challenge_plays",
        sa.Column("bonus_expires_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "daily_challenge_plays",
        sa.Column("bonus_used", sa.Integer(), nullable=False, server_default="0"),
    )


def downgrade() -> None:
    op.drop_column("daily_challenge_plays", "bonus_used")
    op.drop_column("daily_challenge_plays", "bonus_expires_at")
