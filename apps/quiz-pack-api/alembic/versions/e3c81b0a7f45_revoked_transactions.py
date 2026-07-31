"""Server-side StoreKit revocation record `revoked_transactions` (#133 close-out gate 2).

The JWS-only revocation gate shipped in `8b208b60` is bypassable by replay: a
client that kept the Apple-signed bytes it received *before* the refund can
re-present them forever, because those bytes carry no `revocationDate`. This
table is the server-side memory that closes it — the App Store Server
Notifications V2 consumer (`POST /v1/appstore/notifications`) writes a row on
REFUND/REVOKE, and every purchase-authorising call site checks it.

Additive only: one new table, no changes to existing ones, so a deploy running
the previous build against this schema is unaffected.

Revision ID: e3c81b0a7f45
Revises: b4d9e17c3a52
Create Date: 2026-07-31
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "e3c81b0a7f45"
down_revision = "b4d9e17c3a52"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "revoked_transactions",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("transaction_id", sa.String(128), nullable=False),
        sa.Column("original_transaction_id", sa.String(128), nullable=True),
        sa.Column("product_id", sa.String(64), nullable=True),
        sa.Column("notification_type", sa.String(64), nullable=False),
        sa.Column("notification_subtype", sa.String(64), nullable=True),
        sa.Column("notification_uuid", sa.String(64), nullable=True),
        sa.Column("revocation_date", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revocation_reason", sa.Integer(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
    )
    # The revocation check runs on the hot purchase path and matches on EITHER
    # id (a refund inside a subscription family must deny its siblings), so
    # both columns are indexed.
    # UNIQUE: Apple retries a notification until it gets a 200, so a redelivery
    # must collide here and replay as a no-op instead of inserting a second
    # revocation row for one refund.
    op.create_index(
        "ix_revoked_transactions_transaction_id",
        "revoked_transactions",
        ["transaction_id"],
        unique=True,
    )
    op.create_index(
        "ix_revoked_transactions_original_transaction_id",
        "revoked_transactions",
        ["original_transaction_id"],
    )
    op.create_index(
        "ix_revoked_transactions_notification_uuid",
        "revoked_transactions",
        ["notification_uuid"],
    )


def downgrade() -> None:
    # Forward-only per R8.
    pass
