"""Persist the open-question answer gist `questions.headline_answer` (#133 V7).

Open/lateral-puzzle questions carry TWO answers: a long `explanation`-style
resolution in `correct_answer`, and the short gettable gist a player would
actually say aloud in `headline_answer` (#46 D7). The evaluator scores against
`headline_answer or correct_answer`, and the reveal shows the gist — but the
column never existed, so every generated gist was silently dropped at persist
and the played question was graded against the long resolution instead.

A fallback masked the loss while it was survivable: `Question.from_dict` mirrors
`headline_answer` into `correct_answer` when the open prompt complies with
`correct_answer: null`. That only covers the single-answer case; a question
emitting BOTH fields lost the gist outright.

Old rows stay NULL. That is correct, not a gap: the same `from_dict` fallback
already folded their gist into `correct_answer`, so scoring and reveal keep
working exactly as they do today — a NULL here means "gist already inlined",
not "gist missing".

Revision ID: b4d9e17c3a52
Revises: a3f7c81d92be
Create Date: 2026-07-30
"""

import sqlalchemy as sa
from alembic import op

revision = "b4d9e17c3a52"
down_revision = "a3f7c81d92be"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "questions",
        sa.Column("headline_answer", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    # Forward-only per R8.
    pass
