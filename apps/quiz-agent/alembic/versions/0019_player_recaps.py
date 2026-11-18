"""player recap snapshots (#213.3)

Revision ID: 0019_player_recaps
Revises: 0018_analytics_subject_idx
Create Date: 2026-10-28

Expand only: one new table, nothing existing changes.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0019_player_recaps"
down_revision: Union[str, Sequence[str], None] = "0018_analytics_subject_idx"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "player_recaps",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("subject_id", sa.Text(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("period_start", sa.Date(), nullable=False),
        sa.Column("payload", postgresql.JSONB(), nullable=False),
        sa.Column("schema_version", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("seen_at", sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint(
            "subject_id", "kind", "period_start", name="uq_player_recaps_period"
        ),
    )
    op.create_index("ix_player_recaps_subject_id", "player_recaps", ["subject_id"])


def downgrade() -> None:
    op.drop_index("ix_player_recaps_subject_id", table_name="player_recaps")
    op.drop_table("player_recaps")
