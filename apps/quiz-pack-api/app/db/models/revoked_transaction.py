"""`revoked_transactions` ORM table (issue #133 close-out, gate 2).

The durable half of the StoreKit revocation pipeline. Apple's App Store Server
Notifications V2 tell us a purchase was refunded or family-revoked; this table
remembers that fact so a *replayed pre-refund JWS* — genuinely Apple-signed,
carrying no revocation fields, valid forever — can never buy anything again.
Without it the JWS-only gate in `storekit/verifier.py` is bypassable by any
client that kept the bytes it received at purchase time.

Write-once by design: rows are only ever inserted, never cleared on a
`REFUND_REVERSED`. Reversing a revocation is a *grant* decision, and this
pipeline deliberately only ever takes value away (same one-way rule as
quiz-agent's RC transfer handling) — restoring a reversed refund is a founder
action, not something a webhook may do unattended.
"""

from __future__ import annotations

from datetime import datetime
from typing import Optional

from sqlalchemy import DateTime, Integer, String, text
from sqlalchemy.orm import Mapped, mapped_column

from ..base import Base, UUIDPrimaryKeyMixin


class RevokedTransaction(Base, UUIDPrimaryKeyMixin):
    __tablename__ = "revoked_transactions"

    # The refunded transaction itself. Unique because Apple retries a
    # notification until it gets a 200 — the second delivery must be a no-op
    # replay, not a second row.
    transaction_id: Mapped[str] = mapped_column(
        String(128), nullable=False, unique=True, index=True
    )
    # The purchase family (a subscription's renewals all share it). Indexed
    # because the revocation check matches on EITHER id: a refund on one
    # transaction in a subscription family must also deny its siblings.
    original_transaction_id: Mapped[Optional[str]] = mapped_column(
        String(128), nullable=True, index=True
    )
    product_id: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)

    # Provenance of the revocation — which notification told us, so a disputed
    # revocation can be traced back to Apple's delivery.
    notification_type: Mapped[str] = mapped_column(String(64), nullable=False)
    notification_subtype: Mapped[Optional[str]] = mapped_column(
        String(64), nullable=True
    )
    notification_uuid: Mapped[Optional[str]] = mapped_column(
        String(64), nullable=True, index=True
    )

    # Apple's own revocation stamp from the signed transaction (may be absent
    # on a REVOKE, which is why neither column is required).
    revocation_date: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    revocation_reason: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )
