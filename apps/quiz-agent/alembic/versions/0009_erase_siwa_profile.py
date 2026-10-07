"""erase stored Sign in with Apple email and name (GDPR data minimisation)

Revision ID: 0009_erase_siwa_profile
Revises: 0008_analytics_events
Create Date: 2026-10-07

Founder decision 2026-10-07: nothing uses the Apple-supplied email/name, so the
server stops storing them (the app no longer requests them either) and erases
what it already holds. Data-only migration: the ``users.email`` / ``full_name``
columns stay (no schema change, nullable forever after).
"""

from typing import Sequence, Union

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0009_erase_siwa_profile"
down_revision: Union[str, Sequence[str], None] = "0008_analytics_events"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.execute("UPDATE users SET email = NULL, full_name = NULL")


def downgrade() -> None:
    """Downgrade schema.

    No-op: the erased email/name cannot be restored, and must not be (the
    point of the upgrade is that the data is gone)."""
