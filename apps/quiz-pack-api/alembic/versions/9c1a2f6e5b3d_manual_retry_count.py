"""Separate manual-retry budget from the auto-retry attempt counter (#103 F1).

`generation_jobs.retry_count` is set to the ARQ `job_try` on every failure
(`app/worker/tasks.py::_handle_failure`), so a genuinely `failed` order
*always* has `retry_count == max_tries` (3) — the manual `/retry` endpoint's
`retry_count >= 3` cap therefore rejected every real failure, never just
exhausted ones. `manual_retry_count` tracks the budget the manual endpoint
actually gates on, independent of how many automatic ARQ attempts ran.

Revision ID: 9c1a2f6e5b3d
Revises: 4d8e2b7c1f0a
Create Date: 2026-07-17
"""

import sqlalchemy as sa
from alembic import op

revision = "9c1a2f6e5b3d"
down_revision = "4d8e2b7c1f0a"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "generation_jobs",
        sa.Column(
            "manual_retry_count",
            sa.Integer(),
            nullable=False,
            server_default=sa.text("0"),
        ),
    )


def downgrade() -> None:
    # Forward-only per R8.
    pass
