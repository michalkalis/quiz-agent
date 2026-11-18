"""`questions.age_band` — child age band a question is written for (#236).

Founder 2026-11-15: a family section "S deťmi" with questions written for
children aged 4-6, 7-9 and 10-12. Such a question must never reach the
ordinary quiz or the daily challenge, so it carries its band here and the live
retriever (`apps/quiz-agent`) keeps only `age_band IS NULL` rows unless a
session asks for exactly one band. Values: `kids_4_6` | `kids_7_9` |
`kids_10_12` (the custom-pack order's `audience` strings).

This is NOT `age_appropriate` ("suitable from this age": all/8+/12+/16+); that
column stays untouched.

Nullable, no default: NULL = an ordinary question, which is every existing row.

Deploy order: quiz-agent selects every declared column of `questions`, so this
migration must reach prod (quiz-pack-api deploy, `release_command`) before the
quiz-agent build that reads `age_band`.

Revision ID: c236a0b1d2e3
Revises: ba16b5c4cec9
Create Date: 2026-11-18
"""

import sqlalchemy as sa
from alembic import op

revision = "c236a0b1d2e3"
down_revision = "ba16b5c4cec9"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "questions",
        sa.Column("age_band", sa.String(length=16), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("questions", "age_band")
