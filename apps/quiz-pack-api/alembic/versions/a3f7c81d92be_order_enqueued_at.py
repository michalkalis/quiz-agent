"""Track when an order was last parked at 'pending' (#133 item 1e).

The stuck-order sweep's `pending` branch measured
`generation_orders.created_at`, which for a *requeued* order (manual /retry or
a sweep recovery) is as old as the purchase itself. A sweep tick landing in the
few ms between "park at pending" and "enqueue" therefore saw a live requeue as
stuck and enqueued a SECOND paid pipeline for one purchase (double LLM + Tavily
spend, two packs with one orphaned). `enqueued_at` is bumped by every writer
that parks an order at 'pending', so the sweep measures the age of the *queue
handoff* instead of the age of the order.

Existing rows backfill from `created_at`: for a never-requeued order the two
are equal, which is exactly the semantics the old predicate assumed.

Revision ID: a3f7c81d92be
Revises: 9c1a2f6e5b3d
Create Date: 2026-07-30
"""

import sqlalchemy as sa
from alembic import op

revision = "a3f7c81d92be"
down_revision = "9c1a2f6e5b3d"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "generation_orders",
        sa.Column(
            "enqueued_at",
            sa.DateTime(timezone=True),
            nullable=True,
            server_default=sa.text("now()"),
        ),
    )
    op.execute("UPDATE generation_orders SET enqueued_at = created_at")
    op.alter_column("generation_orders", "enqueued_at", nullable=False)


def downgrade() -> None:
    # Forward-only per R8.
    pass
