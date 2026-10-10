"""voice_samples table (issue #197 — car answer recordings for replay tests)

Revision ID: 0011_voice_samples
Revises: 0010_tts_chars
Create Date: 2026-10-10

Metadata for answer recordings the founder's TestFlight build uploads when the
"Save answer recordings" switch is on. The WAV lives in a private R2 bucket
(``r2_key``); ``label`` is filled later by the labeling page (track 197.3).
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0011_voice_samples"
down_revision: Union[str, Sequence[str], None] = "0010_tts_chars"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "voice_samples",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", sa.Text(), nullable=False),
        sa.Column("session_id", sa.Text(), nullable=True),
        sa.Column("question_id", sa.Text(), nullable=True),
        sa.Column("language", sa.Text(), nullable=True),
        sa.Column("sidecar", postgresql.JSONB(), nullable=False),
        sa.Column("r2_key", sa.Text(), nullable=False),
        sa.Column("audio_bytes", sa.Integer(), nullable=False),
        sa.Column("label", postgresql.JSONB(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("r2_key", name="voice_samples_r2_key_key"),
    )
    op.create_index("ix_voice_samples_user_id", "voice_samples", ["user_id"])
    op.create_index("ix_voice_samples_created_at", "voice_samples", ["created_at"])


def downgrade() -> None:
    op.drop_index("ix_voice_samples_created_at", table_name="voice_samples")
    op.drop_index("ix_voice_samples_user_id", table_name="voice_samples")
    op.drop_table("voice_samples")
