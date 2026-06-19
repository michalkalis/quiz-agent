"""app attest tables: attest_challenges, app_attest_keys

Revision ID: 0002_app_attest
Revises: 0001_auth_phase1
Create Date: 2026-06-19

Issue #60 Part B — App Attest hardening. ``attest_challenges`` holds single-use
short-TTL nonces; ``app_attest_keys`` stores one hardware-attested public key
per install plus the monotonic sign counter used as the assertion replay guard.
"""

from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0002_app_attest"
down_revision: Union[str, Sequence[str], None] = "0001_auth_phase1"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "attest_challenges",
        sa.Column("challenge", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("used_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("challenge"),
    )

    op.create_table(
        "app_attest_keys",
        sa.Column("key_id", sa.Text(), nullable=False),
        sa.Column("anon_id", sa.Text(), nullable=True),
        sa.Column("public_key", sa.LargeBinary(), nullable=False),
        sa.Column(
            "sign_counter",
            sa.Integer(),
            server_default="0",
            nullable=False,
        ),
        sa.Column("environment", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["anon_id"],
            ["anonymous_identities.anon_id"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("key_id"),
    )
    op.create_index("ix_app_attest_keys_anon_id", "app_attest_keys", ["anon_id"])


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index("ix_app_attest_keys_anon_id", table_name="app_attest_keys")
    op.drop_table("app_attest_keys")
    op.drop_table("attest_challenges")
