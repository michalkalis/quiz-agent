"""`questions.local_scope` — "skip local questions" label (#206).

Founder 2026-10-15: a player can choose to skip questions only people from one
country understand (Bratislava public transport, the Czech card game prší). The
local-scope classifier stamps the country such a question is tied to here (ISO
3166-1 alpha-2, lowercase); the live retriever (`apps/quiz-agent`) keeps only
`local_scope IS NULL` rows for a session that opted out.

Nullable, no default: NULL = universal, which is also every row the classifier
has not labelled yet (fail-safe direction: a missing label never hides a
question). Whether a row was classified at all lives in
`provenance.extra.local_scope`, so the backfill is resumable without a second
column.

Deploy order: quiz-agent selects every declared column of `questions`, so this
migration must reach prod (quiz-pack-api deploy, `release_command`) before the
quiz-agent build that reads `local_scope`.

Revision ID: a206c0a1e5b7
Revises: b207e5a0c1d2
Create Date: 2026-10-22
"""

import sqlalchemy as sa
from alembic import op

revision = "a206c0a1e5b7"
down_revision = "b207e5a0c1d2"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "questions",
        sa.Column("local_scope", sa.String(length=8), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("questions", "local_scope")
