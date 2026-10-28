"""multiplayer rooms: how guests find a host's game (#212)

Revision ID: 0017_multiplayer_rooms
Revises: 0016_shared_app_state
Create Date: 2026-10-28

Expand only: one new table, nothing existing changes.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0017_multiplayer_rooms"
down_revision: Union[str, Sequence[str], None] = "0016_shared_app_state"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "multiplayer_rooms",
        sa.Column("room_id", sa.Text(), primary_key=True),
        sa.Column("session_id", sa.Text(), nullable=False),
        sa.Column("host_subject_id", sa.Text(), nullable=False),
        sa.Column("join_token", sa.Text(), nullable=False, unique=True),
        sa.Column("net_v4", sa.Text(), nullable=True),
        sa.Column("net_v6", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index(
        "ix_multiplayer_rooms_host_subject_id",
        "multiplayer_rooms",
        ["host_subject_id"],
    )
    op.create_index("ix_multiplayer_rooms_net_v4", "multiplayer_rooms", ["net_v4"])
    op.create_index("ix_multiplayer_rooms_net_v6", "multiplayer_rooms", ["net_v6"])


def downgrade() -> None:
    op.drop_table("multiplayer_rooms")
