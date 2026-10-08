"""daily_usage.tts_chars: per-user daily billed-TTS character counter (#193.13)

Revision ID: 0010_tts_chars
Revises: 0009_erase_siwa_profile
Create Date: 2026-10-08
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0010_tts_chars"
down_revision: Union[str, Sequence[str], None] = "0009_erase_siwa_profile"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "daily_usage",
        sa.Column("tts_chars", sa.Integer(), nullable=False, server_default="0"),
    )


def downgrade() -> None:
    op.drop_column("daily_usage", "tts_chars")
