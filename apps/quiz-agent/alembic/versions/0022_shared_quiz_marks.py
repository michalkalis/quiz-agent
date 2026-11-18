"""per-question marks on shared quizzes (#232 — share a quiz by link, 232.2b)

Revision ID: 0022_shared_quiz_marks
Revises: 0021_apple_refresh_client_id
Create Date: 2026-11-14

Expand only: two nullable JSONB columns. Each holds one entry per question of
the share, in the share's order: true (knew it), false (did not) or null (not
played). NULL = recorded before marks existed.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0022_shared_quiz_marks"
down_revision: Union[str, Sequence[str], None] = "0021_apple_refresh_client_id"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "shared_quizzes",
        sa.Column(
            "sender_marks", postgresql.JSONB(astext_type=sa.Text()), nullable=True
        ),
    )
    op.add_column(
        "shared_quiz_results",
        sa.Column("marks", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("shared_quiz_results", "marks")
    op.drop_column("shared_quizzes", "sender_marks")
