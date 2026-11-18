"""`generation_orders.storekit_environment` — which App Store paid (#207 207.5).

Founder 2026-10-16: the mba backup worker runs on the founder's Claude
subscription, so it may generate only beta-testing orders (bought in the
StoreKit Sandbox, i.e. TestFlight). An App Store customer's order must never
be generated on the subscription. The environment is in the verified JWS at
order creation but was never stored, so the backup could not tell the two
apart.

Nullable, no default: NULL = unknown (every existing row, admin-key orders),
which the backup treats as not eligible — fail closed. Values are Apple's two
store environments only.

Revision ID: b207e5a0c1d2
Revises: e195b0057a11
Create Date: 2026-10-16
"""

import sqlalchemy as sa
from alembic import op

revision = "b207e5a0c1d2"
down_revision = "e195b0057a11"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "generation_orders",
        sa.Column("storekit_environment", sa.String(16), nullable=True),
    )
    op.create_check_constraint(
        "ck_orders_storekit_environment",
        "generation_orders",
        "storekit_environment IS NULL OR storekit_environment IN ('Sandbox','Production')",
    )


def downgrade() -> None:
    op.drop_constraint("ck_orders_storekit_environment", "generation_orders", type_="check")
    op.drop_column("generation_orders", "storekit_environment")
