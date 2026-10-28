"""analytics_events: (subject_id, occurred_at) index for player stats (#213)

Revision ID: 0018_analytics_subject_idx
Revises: 0017_multiplayer_rooms
Create Date: 2026-10-28

The stats endpoint reads one player's events in a time window; the composite
index serves that and also every lookup the single-column ``subject_id`` index
served, so the old one is dropped.
"""

from typing import Sequence, Union

from alembic import op

revision: str = "0018_analytics_subject_idx"
down_revision: Union[str, Sequence[str], None] = "0017_multiplayer_rooms"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_index(
        "ix_analytics_events_subject_occurred",
        "analytics_events",
        ["subject_id", "occurred_at"],
    )
    op.drop_index("ix_analytics_events_subject_id", table_name="analytics_events")


def downgrade() -> None:
    op.create_index(
        "ix_analytics_events_subject_id", "analytics_events", ["subject_id"]
    )
    op.drop_index("ix_analytics_events_subject_occurred", table_name="analytics_events")
