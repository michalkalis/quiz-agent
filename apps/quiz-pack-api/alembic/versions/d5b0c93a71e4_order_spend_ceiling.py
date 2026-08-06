"""Per-order spend ceiling groundwork (#145 — pack order spend ceiling).

Two additive columns on `generation_jobs`:

- `attempt_seq` — monotonic arq enqueue sequence. `attempt_job_id` keys on this
  instead of `retry_count`, which is what forced `/retry` to zero the auto-retry
  counter (and so handed every manual retry a fresh 3-attempt budget: ~12 paid
  frontier pipeline runs for one ~€4.99 purchase).
- `cumulative_cost_cents` — spend accumulated across ALL attempts of one order,
  success or failure. `total_cost_cents` keeps its meaning (the delivered pack's
  run); cost used to be recorded on the success path only, so the runaway spend
  left no trace to check a ceiling against.

Both default 0, so existing rows carry their real history forward (a job that
already ran attempts simply starts accounting from now — prod has no real users
yet, #145 is pre-GA).

Revision ID: d5b0c93a71e4
Revises: e3c81b0a7f45
Create Date: 2026-08-06
"""

import sqlalchemy as sa
from alembic import op

revision = "d5b0c93a71e4"
down_revision = "e3c81b0a7f45"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "generation_jobs",
        sa.Column(
            "cumulative_cost_cents",
            sa.Integer(),
            nullable=False,
            server_default=sa.text("0"),
        ),
    )
    op.add_column(
        "generation_jobs",
        sa.Column(
            "attempt_seq",
            sa.Integer(),
            nullable=False,
            server_default=sa.text("0"),
        ),
    )


def downgrade() -> None:
    # Forward-only per R8.
    pass
