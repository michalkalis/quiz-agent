"""refresh_tokens.anon_id → generic subject id (drop FK to anonymous_identities)

Revision ID: 0004_refresh_subject
Revises: 0003_users
Create Date: 2026-06-27

Issue #61 — Sign in with Apple. A refresh token's subject can now be a real
account (``users.id``) as well as an anonymous identity, because ``/auth/apple``
issues the account's first refresh token. ``refresh_tokens.anon_id`` is therefore
generalised to a plain subject id, and the FK to ``anonymous_identities.anon_id``
(with ON DELETE CASCADE, added in 0001) is dropped — a user-subject token's id
lives in ``users``, not ``anonymous_identities``, so the constraint would reject
it. The column + index stay; account deletion (#61 Session C) revokes/removes a
user's refresh tokens explicitly rather than relying on the cascade.
"""

from typing import Sequence, Union

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "0004_refresh_subject"
down_revision: Union[str, Sequence[str], None] = "0003_users"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Postgres auto-named the unnamed FK from 0001 by the <table>_<column>_fkey rule.
_FK_NAME = "refresh_tokens_anon_id_fkey"


def upgrade() -> None:
    """Upgrade schema."""
    op.drop_constraint(_FK_NAME, "refresh_tokens", type_="foreignkey")


def downgrade() -> None:
    """Downgrade schema. Re-adds the anon-only FK; only round-trips cleanly while
    no user-subject refresh tokens exist (a deliberate one-way generalisation)."""
    op.create_foreign_key(
        _FK_NAME,
        "refresh_tokens",
        "anonymous_identities",
        ["anon_id"],
        ["anon_id"],
        ondelete="CASCADE",
    )
