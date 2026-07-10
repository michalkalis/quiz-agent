"""subscription IAP: product / subscription / credit_ledger tables (issue #93)

Revision ID: 0005_subscription_tables
Revises: 0004_refresh_subject
Create Date: 2026-07-10

Issue #93 — RevenueCat-backed subscription + consumable question packs.
Net-new tables replacing the client-local ``daily_usage.is_premium`` hack with
a server-side entitlement model (Design §1). No data to migrate — prod is
founder-only, so this migration does NOT backfill or touch ``is_premium``; the
column stays in place, unread by the gate, dropped in a later cleanup.

- ``product`` — catalog row per RevenueCat product/entitlement id. Seeded here
  with the 3 pinned ids (Design §1: "Pinned RC / App Store identifiers").
- ``subscription`` — one active-sub projection per durable account.
  ``account_id`` is PK/UNIQUE: it is the webhook upsert's ``ON CONFLICT``
  target and the account id the anon->sign-in fold re-keys to.
- ``credit_ledger`` — append-only consumable-pack balance ledger. Split
  idempotency (flaw fix 1): two *partial* unique indexes, disjoint by
  ``kind``, so a GRANT (deduped on ``store_txn_id``) and its CLAWBACK
  (deduped on ``rc_event_id``) never collide despite sharing the same
  ``store_txn_id``.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0005_subscription_tables"
down_revision: Union[str, Sequence[str], None] = "0004_refresh_subject"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Pinned RC / App Store identifiers (issue #93 Design §1 — seed + iOS offerings
# both hardcode these exact strings).
_PRODUCTS = [
    {
        "product_id": "com.carquiz.unlimited.monthly",
        "kind": "subscription",
        "tier": "unlimited",
        "credit_amount": None,
    },
    {
        "product_id": "com.carquiz.unlimited.annual",
        "kind": "subscription",
        "tier": "unlimited",
        "credit_amount": None,
    },
    {
        "product_id": "com.carquiz.pack.questions100",
        "kind": "consumable",
        "tier": "unlimited",
        "credit_amount": 100,
    },
]


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "product",
        sa.Column("product_id", sa.Text(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("tier", sa.Text(), nullable=False),
        sa.Column("credit_amount", sa.Integer(), nullable=True),
        sa.PrimaryKeyConstraint("product_id"),
    )

    op.create_table(
        "subscription",
        sa.Column("account_id", sa.Text(), nullable=False),
        sa.Column("product_id", sa.Text(), nullable=False),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("rc_original_txn_id", sa.Text(), nullable=False),
        sa.Column("last_event_ts_ms", sa.BigInteger(), nullable=True),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["product_id"], ["product.product_id"]),
        sa.PrimaryKeyConstraint("account_id"),
        # account_id is already PK, so PK == UNIQUE; no separate constraint
        # needed (matches Design §1 "account_id PK/UNIQUE").
    )

    op.create_table(
        "credit_ledger",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            nullable=False,
        ),
        sa.Column("account_id", sa.Text(), nullable=False),
        sa.Column("delta", sa.Integer(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("store_txn_id", sa.Text(), nullable=True),
        sa.Column("rc_event_id", sa.Text(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_credit_ledger_account_id", "credit_ledger", ["account_id"])
    # Split idempotency (flaw fix 1): partial unique indexes, disjoint by kind.
    op.create_index(
        "ix_credit_ledger_grant_store_txn_id",
        "credit_ledger",
        ["store_txn_id"],
        unique=True,
        postgresql_where=sa.text("kind = 'grant'"),
    )
    op.create_index(
        "ix_credit_ledger_clawback_rc_event_id",
        "credit_ledger",
        ["rc_event_id"],
        unique=True,
        postgresql_where=sa.text("kind = 'clawback'"),
    )

    # Seed the 3 pinned products — read-only catalog rows.
    product_table = sa.table(
        "product",
        sa.column("product_id", sa.Text()),
        sa.column("kind", sa.Text()),
        sa.column("tier", sa.Text()),
        sa.column("credit_amount", sa.Integer()),
    )
    op.bulk_insert(product_table, _PRODUCTS)


def downgrade() -> None:
    """Downgrade schema. Tables-only — no ``is_premium`` was touched, so there
    is nothing else to reverse."""
    op.drop_table("credit_ledger")
    op.drop_table("subscription")
    op.drop_table("product")
