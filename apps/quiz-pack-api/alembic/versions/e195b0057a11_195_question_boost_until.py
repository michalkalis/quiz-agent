"""`questions.boost_until` — fresh-question selection boost (#195).

Founder 2026-10-08: topical questions (recent entertainment news) should be
picked ~2× as often as ordinary ones, but only while they are topical. The
generation pipeline's topicality classifier stamps the end of that window here;
the live retriever (`apps/quiz-agent`) weighs a candidate with
`boost_until > now()` higher in its final pick.

Nullable, no default: NULL = never boosted, which is every existing row and
the right meaning for the general corpus. "Permanently boosted" is a far-future
sentinel date (Python `datetime` cannot hold Postgres `infinity`). This is NOT
the #76 `expires_at` expiry — that column stays untouched and still hides a
stale question; `boost_until` never hides anything.

Deploy order: quiz-agent selects every declared column of `questions`, so this
migration must reach prod (quiz-pack-api deploy, `release_command`) before the
quiz-agent build that reads `boost_until`.

Revision ID: e195b0057a11
Revises: b182a1c2d3e4
Create Date: 2026-10-08
"""

import sqlalchemy as sa
from alembic import op

revision = "e195b0057a11"
down_revision = "b182a1c2d3e4"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "questions",
        sa.Column("boost_until", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    # Forward-only per R8.
    pass
