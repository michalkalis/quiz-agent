"""environment column on subscription + credit_ledger (issue #101)

Revision ID: 0006_rc_environment
Revises: 0005_subscription_tables
Create Date: 2026-07-16

Issue #101 — prod vs sandbox environment separation. Every RC write path now
stamps the normalized store environment (``PRODUCTION``/``SANDBOX``) so money
rows are auditable per environment and the entitlement read gate can honor
only rows matching the deployment's ``RC_ALLOWED_ENVIRONMENT``.

Nullable on purpose: pre-#101 rows have no recorded environment (NULL). The
read gate treats NULL as NOT entitled; the §3.6 quarantine pass later deletes
sandbox-origin rows and stamps genuine survivors ``PRODUCTION``.
"""

from typing import Sequence, Union

import sqlalchemy as sa

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0006_rc_environment"
down_revision: Union[str, Sequence[str], None] = "0005_subscription_tables"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column("subscription", sa.Column("environment", sa.Text(), nullable=True))
    op.add_column("credit_ledger", sa.Column("environment", sa.Text(), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("credit_ledger", "environment")
    op.drop_column("subscription", "environment")
