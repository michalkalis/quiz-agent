"""analytics_events table (issue #51 — first-party product analytics)

Revision ID: 0008_analytics_events
Revises: 0007_feedback_table
Create Date: 2026-10-07

Append-only product events (server-emitted + a few client-only events posted
by the app). Replaces the abandoned plan to send them to Sentry: our own table
gives funnels/retention by plain SQL and keeps the data in one place.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0008_analytics_events"
down_revision: Union[str, Sequence[str], None] = "0007_feedback_table"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "analytics_events",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("subject_id", sa.Text(), nullable=True),
        sa.Column("session_id", sa.Text(), nullable=True),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("app_version", sa.Text(), nullable=True),
        sa.Column("properties", postgresql.JSONB(), nullable=False),
    )
    op.create_index(
        "ix_analytics_events_name_occurred",
        "analytics_events",
        ["name", "occurred_at"],
    )
    op.create_index(
        "ix_analytics_events_subject_id", "analytics_events", ["subject_id"]
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index("ix_analytics_events_subject_id", table_name="analytics_events")
    op.drop_index("ix_analytics_events_name_occurred", table_name="analytics_events")
    op.drop_table("analytics_events")
