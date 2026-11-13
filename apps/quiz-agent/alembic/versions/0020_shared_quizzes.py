"""shared quizzes and their results (#232 — share a quiz by link)

Revision ID: 0020_shared_quizzes
Revises: 0019_player_recaps
Create Date: 2026-11-13

Expand only: two new tables, nothing existing changes.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0020_shared_quizzes"
down_revision: Union[str, Sequence[str], None] = "0019_player_recaps"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "shared_quizzes",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("token", sa.Text(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("language", sa.Text(), nullable=False),
        sa.Column(
            "question_ids", postgresql.JSONB(astext_type=sa.Text()), nullable=False
        ),
        sa.Column("pack_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("challenge_date", sa.Date(), nullable=True),
        sa.Column("title", sa.Text(), nullable=True),
        sa.Column("topic", sa.Text(), nullable=True),
        sa.Column("source_session_id", sa.Text(), nullable=True),
        sa.Column("sender_subject_id", sa.Text(), nullable=False),
        sa.Column("sender_name", sa.Text(), nullable=True),
        sa.Column("sender_score", sa.Float(), nullable=True),
        sa.Column("sender_total", sa.Integer(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ux_shared_quizzes_token", "shared_quizzes", ["token"], unique=True)
    op.create_index("ix_shared_quizzes_sender", "shared_quizzes", ["sender_subject_id"])
    op.create_index(
        "ux_shared_quizzes_sender_session",
        "shared_quizzes",
        ["sender_subject_id", "source_session_id"],
        unique=True,
        postgresql_where=sa.text("source_session_id IS NOT NULL AND pack_id IS NULL"),
    )
    op.create_index(
        "ux_shared_quizzes_sender_pack",
        "shared_quizzes",
        ["sender_subject_id", "pack_id"],
        unique=True,
        postgresql_where=sa.text("pack_id IS NOT NULL"),
    )
    op.create_table(
        "shared_quiz_results",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "shared_quiz_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("shared_quizzes.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("subject_id", sa.Text(), nullable=False),
        sa.Column("display_name", sa.Text(), nullable=True),
        sa.Column("session_id", sa.Text(), nullable=True),
        sa.Column("score", sa.Float(), nullable=True),
        sa.Column("total", sa.Integer(), nullable=True),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint(
            "shared_quiz_id", "subject_id", name="uq_shared_quiz_results_person"
        ),
    )
    op.create_index(
        "ix_shared_quiz_results_subject_id", "shared_quiz_results", ["subject_id"]
    )


def downgrade() -> None:
    op.drop_index("ix_shared_quiz_results_subject_id", table_name="shared_quiz_results")
    op.drop_table("shared_quiz_results")
    op.drop_index("ux_shared_quizzes_sender_pack", table_name="shared_quizzes")
    op.drop_index("ux_shared_quizzes_sender_session", table_name="shared_quizzes")
    op.drop_index("ix_shared_quizzes_sender", table_name="shared_quizzes")
    op.drop_index("ux_shared_quizzes_token", table_name="shared_quizzes")
    op.drop_table("shared_quizzes")
