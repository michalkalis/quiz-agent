"""voice_experiment_arms table (issue #204 task 204.9 — automatic voice-settings testing)

Revision ID: 0012_voice_experiment_arms
Revises: 0011_voice_samples
Create Date: 2026-10-14

One row per tested setting × audio route group. The app reads it through
``GET /app-config``; the weekly evaluator flips a row to ``winner_on`` or
``off``. Seeded so the test starts the moment the app ships: every setting
that can matter on a route runs at 50/50; echo cancellation off the car /
Bluetooth route can never take effect, so it starts ``off``.
"""

from datetime import datetime, timezone
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0012_voice_experiment_arms"
down_revision: Union[str, Sequence[str], None] = "0011_voice_samples"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# (flag, route_group, status, p_on, decision_reason)
_SEED = [
    ("neural_vad", "bt_car", "running", 0.5, None),
    ("neural_vad", "other", "running", 0.5, None),
    ("front_mic", "bt_car", "running", 0.5, None),
    ("front_mic", "other", "running", 0.5, None),
    ("aec", "bt_car", "running", 0.5, None),
    ("aec", "other", "off", 0.0, "not_applicable"),
]


def upgrade() -> None:
    table = op.create_table(
        "voice_experiment_arms",
        sa.Column("flag", sa.Text(), primary_key=True),
        sa.Column("route_group", sa.Text(), primary_key=True),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("p_on", sa.Float(), nullable=False),
        sa.Column("generation", sa.Integer(), server_default="1", nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("decided_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("decision_reason", sa.Text(), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    now = datetime.now(timezone.utc)
    op.bulk_insert(
        table,
        [
            {
                "flag": flag,
                "route_group": route,
                "status": status,
                "p_on": p_on,
                "generation": 1,
                "started_at": now,
                # The not-applicable row is decided at birth.
                "decided_at": now if reason else None,
                "decision_reason": reason,
                "updated_at": now,
            }
            for flag, route, status, p_on, reason in _SEED
        ],
    )


def downgrade() -> None:
    op.drop_table("voice_experiment_arms")
