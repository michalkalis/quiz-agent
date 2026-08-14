"""`generation_orders.generation_mode` — server-side direct-mode switch (issue #157, D4).

Nullable column, NULL = grounded (every existing row keeps today's behavior),
so the migration can be applied before the code that reads it
(migrate-before-deploy). Replaces the in-prompt DIRECT GENERATION MODE marker,
which customer order text could abuse to skip sourcing + grounding checks.

Revision ID: f2a91c4b8e57
Revises: a7fa4d9d6751
Create Date: 2026-08-14
"""

import sqlalchemy as sa
from alembic import op

revision = "f2a91c4b8e57"
down_revision = "a7fa4d9d6751"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "generation_orders",
        sa.Column("generation_mode", sa.String(length=16), nullable=True),
    )
    op.create_check_constraint(
        "ck_orders_generation_mode",
        "generation_orders",
        "generation_mode IS NULL OR generation_mode IN ('grounded','direct')",
    )


def downgrade() -> None:
    op.drop_constraint(
        "ck_orders_generation_mode", "generation_orders", type_="check"
    )
    op.drop_column("generation_orders", "generation_mode")
