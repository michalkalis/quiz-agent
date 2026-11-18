"""`generation_orders.difficulty` — buyer-chosen difficulty (issue #224, 224.3).

Nullable column, NULL = mixed batch (every existing row and every older app
build keeps today's behavior), so the migration can be applied before the code
that reads it (migrate-before-deploy).

Revision ID: d4b7e1c9a265
Revises: c3f8a6d2e914
Create Date: 2026-11-02
"""

import sqlalchemy as sa
from alembic import op

revision = "d4b7e1c9a265"
down_revision = "c3f8a6d2e914"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "generation_orders",
        sa.Column("difficulty", sa.String(length=16), nullable=True),
    )
    op.create_check_constraint(
        "ck_orders_difficulty",
        "generation_orders",
        "difficulty IS NULL OR difficulty IN ('easy','medium','hard')",
    )


def downgrade() -> None:
    op.drop_constraint("ck_orders_difficulty", "generation_orders", type_="check")
    op.drop_column("generation_orders", "difficulty")
