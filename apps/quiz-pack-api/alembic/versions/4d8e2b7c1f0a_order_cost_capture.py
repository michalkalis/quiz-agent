"""Per-order cost capture (#95 Session 1, founder decision 5).

Adds measured-spend columns to `generation_orders` so the first founder pack
yields an actual all-in $/question figure (the #72 gap: no real dollar spend
was ever recorded):

- `llm_cost_usd`  — OpenRouter account-usage delta across the generation run
                    (NULL when unmeasurable: direct gateway / credits API down).
- `search_cost_cents` — Tavily spend from the actual per-order search count.

Revision ID: 4d8e2b7c1f0a
Revises: 7a2c91d40b1e
Create Date: 2026-07-12
"""

import sqlalchemy as sa
from alembic import op

revision = "4d8e2b7c1f0a"
down_revision = "7a2c91d40b1e"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "generation_orders",
        sa.Column("llm_cost_usd", sa.Numeric(12, 6), nullable=True),
    )
    op.add_column(
        "generation_orders",
        sa.Column(
            "search_cost_cents",
            sa.Integer(),
            nullable=False,
            server_default=sa.text("0"),
        ),
    )


def downgrade() -> None:
    # Forward-only per R8.
    pass
