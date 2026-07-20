"""feedback table (issue #109 — beta voice feedback)

Revision ID: 0007_feedback_table
Revises: 0006_rc_environment
Create Date: 2026-07-20

Durable inbox for in-app beta feedback: message + device/app metadata plus
optional screenshot/audio/log attachments, all in one row. Bytea is fine at
beta scale (handful of testers, capped per-row at ~16 MB by the endpoint's
size caps); revisit blob storage with the Hetzner migration if volume grows.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0007_feedback_table"
down_revision: Union[str, Sequence[str], None] = "0006_rc_environment"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "feedback",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        # Bearer subject id (nullable: the legacy grace window can pass an
        # unauthenticated caller through with no subject_id, same as other
        # require_auth_or_grace routes).
        sa.Column("user_id", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("message", sa.Text(), nullable=False),
        sa.Column("metadata", postgresql.JSONB(), nullable=True),
        sa.Column("app_version", sa.Text(), nullable=True),
        sa.Column("logs", sa.Text(), nullable=True),
        sa.Column("screenshot", sa.LargeBinary(), nullable=True),
        sa.Column("screenshot_content_type", sa.Text(), nullable=True),
        sa.Column("audio", sa.LargeBinary(), nullable=True),
        sa.Column("audio_content_type", sa.Text(), nullable=True),
    )
    op.create_index("ix_feedback_created_at", "feedback", ["created_at"])
    op.create_index("ix_feedback_user_id", "feedback", ["user_id"])


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index("ix_feedback_user_id", table_name="feedback")
    op.drop_index("ix_feedback_created_at", table_name="feedback")
    op.drop_table("feedback")
