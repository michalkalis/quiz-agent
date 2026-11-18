"""#225 — reuse a finished custom pack for an identical order.

Adds `generation_orders.prompt_key` (match key: hash of the normalized prompt)
and `reused_from_order_id` (the original a copied pack came from), plus the
lookup index. Backfills `prompt_key` for existing orders so packs delivered
before this release can be reused too.

The normalization is copied here on purpose (not imported from the app) so
this revision keeps producing the same keys if the app code moves later; it
must match `app.pack_reuse.prompt_key`.

Revision ID: e5a2c7f1b938
Revises: d4b7e1c9a265
Create Date: 2026-11-02
"""

import hashlib
import unicodedata

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID as PGUUID

revision = "e5a2c7f1b938"
down_revision = "d4b7e1c9a265"
branch_labels = None
depends_on = None


def _prompt_key(prompt: str) -> str:
    folded = unicodedata.normalize("NFKC", prompt).casefold()
    spaced = "".join(" " if unicodedata.category(ch)[0] in "PS" else ch for ch in folded)
    return hashlib.sha256(" ".join(spaced.split()).encode("utf-8")).hexdigest()


def upgrade() -> None:
    op.add_column(
        "generation_orders", sa.Column("prompt_key", sa.String(64), nullable=True)
    )
    op.add_column(
        "generation_orders",
        sa.Column(
            "reused_from_order_id",
            PGUUID(as_uuid=True),
            sa.ForeignKey("generation_orders.id", ondelete="SET NULL"),
            nullable=True,
        ),
    )
    op.create_index(
        "ix_orders_prompt_key", "generation_orders", ["prompt_key", "language"]
    )

    conn = op.get_bind()
    rows = conn.execute(sa.text("SELECT id, prompt FROM generation_orders")).all()
    for order_id, prompt in rows:
        conn.execute(
            sa.text("UPDATE generation_orders SET prompt_key = :k WHERE id = :id"),
            {"k": _prompt_key(prompt), "id": order_id},
        )


def downgrade() -> None:
    op.drop_index("ix_orders_prompt_key", table_name="generation_orders")
    op.drop_column("generation_orders", "reused_from_order_id")
    op.drop_column("generation_orders", "prompt_key")
