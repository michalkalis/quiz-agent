"""daily crew removals (#239 — the daily crew)

Revision ID: 0023_daily_crew_removals
Revises: 0022_shared_quiz_marks
Create Date: 2026-11-18

Expand only: one new table, nothing existing changes.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0023_daily_crew_removals"
down_revision: Union[str, Sequence[str], None] = "0022_shared_quiz_marks"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "daily_crew_removals",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("subject_id", sa.Text(), nullable=False),
        sa.Column("removed_subject_id", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint(
            "subject_id", "removed_subject_id", name="uq_daily_crew_removals_pair"
        ),
    )
    op.create_index(
        "ix_daily_crew_removals_removed", "daily_crew_removals", ["removed_subject_id"]
    )


def downgrade() -> None:
    op.drop_index("ix_daily_crew_removals_removed", table_name="daily_crew_removals")
    op.drop_table("daily_crew_removals")
