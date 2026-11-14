"""users.apple_refresh_token_client_id: which app issued the Apple token (#234)

Revision ID: 0021_apple_refresh_client_id
Revises: 0020_shared_quizzes
Create Date: 2026-11-14

Two apps sign in now (App Store app + TestFlight-only beta). Apple only revokes
a refresh token when the revoke is authenticated as the client that obtained
it, so the account-deletion revoke needs that client id. Nullable: NULL means
the primary client, which issued every token stored before this column.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0021_apple_refresh_client_id"
down_revision: Union[str, Sequence[str], None] = "0020_shared_quizzes"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "users",
        sa.Column("apple_refresh_token_client_id", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("users", "apple_refresh_token_client_id")
