"""Allow 'archived' in questions.review_status (#72 corpus swap).

The founder-ordered corpus swap (2026-07-10) retires the pre-#72 questions
without deleting them: they move to review_status='archived'. The read path
serves only 'approved', so archived rows disappear from the app while staying
recoverable (flip back to 'approved' to restore).

Revision ID: 7a2c91d40b1e
Revises: 1c5e0fa7b3d4
Create Date: 2026-07-10
"""

from alembic import op

revision = "7a2c91d40b1e"
down_revision = "1c5e0fa7b3d4"
branch_labels = None
depends_on = None

STATUSES = "'pending_review','approved','rejected','needs_revision','archived'"


def upgrade() -> None:
    op.drop_constraint("ck_questions_review_status", "questions", type_="check")
    op.create_check_constraint(
        "ck_questions_review_status",
        "questions",
        f"review_status IN ({STATUSES})",
    )


def downgrade() -> None:
    # Forward-only per R8.
    pass
