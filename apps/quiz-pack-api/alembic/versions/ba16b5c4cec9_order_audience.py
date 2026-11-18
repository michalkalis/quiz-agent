"""`generation_orders.audience` — who a custom pack is written for (#236, 236.1).

Nullable column, NULL = an order from a build before the choice, generated for
adults exactly as today, so the migration can be applied before the code that
reads it (migrate-before-deploy). A content setting on the order, never a
person's age.

Revision ID: ba16b5c4cec9
Revises: e5a2c7f1b938
Create Date: 2026-11-15
"""

import sqlalchemy as sa
from alembic import op

revision = "ba16b5c4cec9"
down_revision = "e5a2c7f1b938"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "generation_orders",
        sa.Column("audience", sa.String(length=16), nullable=True),
    )
    op.create_check_constraint(
        "ck_orders_audience",
        "generation_orders",
        "audience IS NULL OR audience IN ('adults','kids_4_6','kids_7_9','kids_10_12')",
    )


def downgrade() -> None:
    op.drop_constraint("ck_orders_audience", "generation_orders", type_="check")
    op.drop_column("generation_orders", "audience")
