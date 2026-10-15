"""daily challenge tables (issue #205 — daily challenge: player vs the crowd)

Revision ID: 0013_daily_challenge
Revises: 0012_voice_experiment_arms
Create Date: 2026-10-15

The day's shared question set per language, one play per subject per date, and
the first graded verdict per question of a play. Expand only.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0013_daily_challenge"
down_revision: Union[str, Sequence[str], None] = "0012_voice_experiment_arms"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "daily_challenge_sets",
        sa.Column("language", sa.Text(), primary_key=True),
        sa.Column("challenge_date", sa.Date(), primary_key=True),
        sa.Column(
            "question_ids", postgresql.JSONB(astext_type=sa.Text()), nullable=False
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "daily_challenge_plays",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("subject_id", sa.Text(), nullable=False),
        sa.Column("challenge_date", sa.Date(), nullable=False),
        sa.Column("language", sa.Text(), nullable=False),
        sa.Column("session_id", sa.Text(), nullable=True),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("score", sa.Integer(), nullable=True),
        sa.Column("spoken_lines", sa.Integer(), server_default="0", nullable=False),
    )
    op.create_index(
        "ux_daily_challenge_plays_subject_date",
        "daily_challenge_plays",
        ["subject_id", "challenge_date"],
        unique=True,
    )
    op.create_index(
        "ix_daily_challenge_plays_lang_date",
        "daily_challenge_plays",
        ["language", "challenge_date"],
    )
    op.create_table(
        "daily_challenge_answers",
        sa.Column(
            "play_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("daily_challenge_plays.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("question_id", sa.Text(), primary_key=True),
        sa.Column("result", sa.Text(), nullable=False),
        sa.Column("knew", sa.Boolean(), nullable=False),
        sa.Column("answered_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("daily_challenge_answers")
    op.drop_index("ix_daily_challenge_plays_lang_date", "daily_challenge_plays")
    op.drop_index("ux_daily_challenge_plays_subject_date", "daily_challenge_plays")
    op.drop_table("daily_challenge_plays")
    op.drop_table("daily_challenge_sets")
