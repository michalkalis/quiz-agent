"""auth phase 1 tables: anonymous_identities, refresh_tokens, daily_usage

Revision ID: 0001_auth_phase1
Revises:
Create Date: 2026-06-18

Issue #60 — server-trusted anonymous identity + persistent daily usage.
Subject columns are TEXT (not UUID) so the 30-day legacy `dev_…` grace path
inserts cleanly (decision D4).
"""

from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0001_auth_phase1"
down_revision: Union[str, Sequence[str], None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "anonymous_identities",
        sa.Column("anon_id", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "is_legacy",
            sa.Boolean(),
            server_default="false",
            nullable=False,
        ),
        sa.Column("upgraded_to_user_id", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("anon_id"),
    )

    op.create_table(
        "refresh_tokens",
        sa.Column("token_hash", sa.Text(), nullable=False),
        sa.Column("family_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("anon_id", sa.Text(), nullable=False),
        sa.Column("issued_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["anon_id"],
            ["anonymous_identities.anon_id"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("token_hash"),
    )
    op.create_index("ix_refresh_tokens_family_id", "refresh_tokens", ["family_id"])
    op.create_index("ix_refresh_tokens_anon_id", "refresh_tokens", ["anon_id"])

    op.create_table(
        "daily_usage",
        sa.Column("subject_id", sa.Text(), nullable=False),
        sa.Column("usage_date", sa.Date(), nullable=False),
        sa.Column(
            "questions_count",
            sa.Integer(),
            server_default="0",
            nullable=False,
        ),
        sa.Column(
            "is_premium",
            sa.Boolean(),
            server_default="false",
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("subject_id", "usage_date"),
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_table("daily_usage")
    op.drop_index("ix_refresh_tokens_anon_id", table_name="refresh_tokens")
    op.drop_index("ix_refresh_tokens_family_id", table_name="refresh_tokens")
    op.drop_table("refresh_tokens")
    op.drop_table("anonymous_identities")
