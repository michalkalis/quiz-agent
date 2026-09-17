"""`question_packs.generation_status` — incremental pack delivery (issue #182).

The worker now persists questions in batches while the pack is still being
generated, so a `question_packs` row no longer implies "complete". This column
tells the live quiz backend whether an empty retrieval means "exhausted"
(`complete` / `failed`) or "more questions are on the way" (`generating`).

Server default `complete` so every existing row keeps today's meaning and
the migration can run before the code that writes it (migrate-before-deploy).

Revision ID: b182a1c2d3e4
Revises: a170c0e5d1b2
Create Date: 2026-09-17
"""

import sqlalchemy as sa
from alembic import op

revision = "b182a1c2d3e4"
down_revision = "a170c0e5d1b2"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "question_packs",
        sa.Column(
            "generation_status",
            sa.String(length=16),
            nullable=False,
            server_default="complete",
        ),
    )
    op.create_check_constraint(
        "ck_packs_generation_status",
        "question_packs",
        "generation_status IN ('generating','complete','failed')",
    )


def downgrade() -> None:
    op.drop_constraint("ck_packs_generation_status", "question_packs", type_="check")
    op.drop_column("question_packs", "generation_status")
