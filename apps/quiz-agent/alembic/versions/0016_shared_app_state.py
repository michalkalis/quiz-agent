"""quiz-agent state off the volume: sessions, leases, ratings, translation
cache, alert state, heartbeats (#207 task 207.20, resilience design step 3)

Revision ID: 0016_shared_app_state
Revises: 0015_app_switches
Create Date: 2026-10-16

Expand only: new tables, nothing existing changes. The previous release keeps
its SQLite files on the volume and never reads these, so old and new machines
can overlap during a rolling deploy.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0016_shared_app_state"
down_revision: Union[str, Sequence[str], None] = "0015_app_switches"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _ts() -> sa.DateTime:
    return sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "quiz_sessions",
        sa.Column("session_id", sa.Text(), primary_key=True),
        sa.Column("data_json", sa.Text(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False),
        sa.Column("expires_at", _ts(), nullable=False),
        sa.Column("created_at", _ts(), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", _ts(), nullable=False, server_default=sa.func.now()),
    )
    op.create_index(
        "ix_quiz_sessions_active_expires",
        "quiz_sessions",
        ["is_active", "expires_at"],
    )
    op.create_table(
        "coordination_leases",
        sa.Column("name", sa.Text(), primary_key=True),
        sa.Column("holder", sa.Text(), nullable=False),
        sa.Column("expires_at", _ts(), nullable=False),
    )
    op.create_table(
        "question_ratings",
        sa.Column("id", sa.Text(), primary_key=True),
        sa.Column("question_id", sa.Text(), nullable=False),
        sa.Column("session_id", sa.Text(), nullable=True),
        sa.Column("user_id", sa.Text(), nullable=True),
        sa.Column("rating", sa.Integer(), nullable=False),
        sa.Column("feedback", sa.Text(), nullable=True),
        sa.Column("was_correct", sa.Boolean(), nullable=True),
        sa.Column("user_answer", sa.Text(), nullable=True),
        sa.Column("difficulty_at_time", sa.Text(), nullable=True),
        sa.Column("created_at", _ts(), nullable=False, server_default=sa.func.now()),
    )
    op.create_index(
        "ix_question_ratings_question_id", "question_ratings", ["question_id"]
    )
    op.create_index("ix_question_ratings_user_id", "question_ratings", ["user_id"])
    op.create_table(
        "translation_cache",
        sa.Column("kind", sa.Text(), primary_key=True),
        sa.Column("source_hash", sa.Text(), primary_key=True),
        sa.Column("target_language", sa.Text(), primary_key=True),
        sa.Column("version", sa.Text(), primary_key=True),
        sa.Column("source_text", sa.Text(), nullable=False),
        sa.Column("translated_text", sa.Text(), nullable=False),
    )
    op.create_table(
        "ops_alert_state",
        sa.Column("source", sa.Text(), primary_key=True),
        sa.Column("state_json", sa.Text(), nullable=False),
        sa.Column("updated_at", _ts(), nullable=False, server_default=sa.func.now()),
    )
    op.create_table(
        "ops_heartbeats",
        sa.Column("name", sa.Text(), primary_key=True),
        sa.Column("seen_at", _ts(), nullable=False),
    )


def downgrade() -> None:
    for table in (
        "ops_heartbeats",
        "ops_alert_state",
        "translation_cache",
        "question_ratings",
        "coordination_leases",
    ):
        op.drop_table(table)
    op.drop_index("ix_quiz_sessions_active_expires", table_name="quiz_sessions")
    op.drop_table("quiz_sessions")
