"""users table — real accounts created by Sign in with Apple

Revision ID: 0003_users
Revises: 0002_app_attest
Create Date: 2026-06-27

Issue #61 — auth Phase 2. One row per account, anchored on Apple's stable
``apple_sub`` (UNIQUE). ``full_name`` stores the name Apple sends only on first
authorization (F5); ``apple_refresh_token_encrypted`` holds the Fernet
ciphertext of Apple's refresh token (F1/F2), nullable because Apple does not
always return one. No ``plan_tier`` — subscriptions are deferred (F8).
"""

from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0003_users"
down_revision: Union[str, Sequence[str], None] = "0002_app_attest"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "users",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("apple_sub", sa.Text(), nullable=False),
        sa.Column("email", sa.Text(), nullable=True),
        sa.Column("full_name", sa.Text(), nullable=True),
        sa.Column("apple_refresh_token_encrypted", sa.LargeBinary(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("apple_sub", name="uq_users_apple_sub"),
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_table("users")
