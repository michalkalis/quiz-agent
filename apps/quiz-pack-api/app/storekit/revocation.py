"""Server-side revocation record: write it, and consult it (#133 close-out gate 2).

Two halves of one money rule — *a reversed purchase buys nothing, forever*:

* `record_revocation` — called by the App Store Server Notifications V2
  consumer on REFUND / REVOKE. Writes the `revoked_transactions` row and
  revokes what that transaction granted here.
* `assert_not_revoked` — called by every purchase-authorising call site
  before it grants anything. This is the half `AppleJWSVerifier` cannot do:
  the verifier is sync and has no DB, and its JWS-only gate only sees
  revocation fields that the presented bytes happen to carry.

Lives in `app.storekit` for the same reason `jws_cache` does (backend arch
review 2026-07-18): it is a StoreKit concern, not a generic DB one.
"""

from __future__ import annotations

import logging
from typing import Optional

import sentry_sdk
from sqlalchemy import or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ..db.models.order import GenerationOrder
from ..db.models.revoked_transaction import RevokedTransaction
from .exceptions import JWSRevoked
from .models import SignedTransaction

logger = logging.getLogger(__name__)


def _transaction_ids(tx: SignedTransaction) -> list[str]:
    """The ids a revocation of `tx` covers: itself and its purchase family."""
    ids = [tx.transaction_id]
    if tx.original_transaction_id and tx.original_transaction_id != tx.transaction_id:
        ids.append(tx.original_transaction_id)
    return ids


async def find_revocation(
    session: AsyncSession, tx: SignedTransaction
) -> Optional[RevokedTransaction]:
    """Return the revocation row covering `tx`, or None.

    Matches on either id in either column: a subscription refund names one
    transaction of a family, and the JWS a client replays may be a renewal
    sibling. Matching only `transaction_id == transaction_id` would let the
    sibling through.
    """
    ids = _transaction_ids(tx)
    stmt = select(RevokedTransaction).where(
        or_(
            RevokedTransaction.transaction_id.in_(ids),
            RevokedTransaction.original_transaction_id.in_(ids),
        )
    )
    return (await session.execute(stmt)).scalars().first()


async def assert_not_revoked(session: AsyncSession, tx: SignedTransaction) -> None:
    """Raise `JWSRevoked` when a notification has already reversed this purchase.

    Deliberately raises the same exception class the verifier's JWS-only gate
    raises, so every call site's existing `except JWSError -> 401` mapping
    covers it without a new branch — one rejection semantic for one money
    fact, whichever half of the pipeline detected it.
    """
    row = await find_revocation(session, tx)
    if row is None:
        return
    raise JWSRevoked(
        f"transaction {tx.transaction_id} was revoked by App Store notification "
        f"{row.notification_type}"
        f"{'/' + row.notification_subtype if row.notification_subtype else ''} "
        f"(recorded {row.created_at.isoformat()})"
    )


async def _revoke_grants(session: AsyncSession, tx: SignedTransaction) -> list[str]:
    """Take back what this transaction bought in *this* service.

    quiz-pack-api grants exactly one kind of value: a pack credit, i.e. a
    `generation_orders` row. Flipping it to the existing `refunded` status is
    the revocation — it drops out of the caller's "my packs" list as a live
    order and can no longer be retried (retry requires `failed`).

    `refund_eligible` is deliberately NOT set: that flag means "we owe this
    customer a refund" (written on our own delivery failures). Apple has
    already refunded here, so setting it would manufacture a second refund
    obligation out of a completed one.

    Returns the ids of the orders revoked (empty when the transaction bought
    something this service does not hold — see the caller's reconciliation
    report).
    """
    ids = _transaction_ids(tx)
    stmt = select(GenerationOrder).where(GenerationOrder.transaction_id.in_(ids))
    orders = (await session.execute(stmt)).scalars().all()
    for order in orders:
        order.status = "refunded"
    return [str(order.id) for order in orders]


async def record_revocation(
    session: AsyncSession,
    tx: SignedTransaction,
    *,
    notification_type: str,
    notification_subtype: Optional[str] = None,
    notification_uuid: Optional[str] = None,
) -> tuple[bool, list[str]]:
    """Persist the revocation and revoke its grants. Idempotent.

    Returns `(newly_recorded, revoked_order_ids)`. A redelivery of the same
    notification returns `(False, [])` — Apple retries until it sees a 200, so
    a second delivery must be a no-op, never a second revocation.
    """
    existing = await find_revocation(session, tx)
    if existing is not None:
        return False, []

    row = RevokedTransaction(
        transaction_id=tx.transaction_id,
        original_transaction_id=tx.original_transaction_id,
        product_id=tx.product_id,
        notification_type=notification_type,
        notification_subtype=notification_subtype,
        notification_uuid=notification_uuid,
        revocation_date=tx.revocation_date,
        revocation_reason=tx.revocation_reason,
    )
    session.add(row)
    revoked_order_ids = await _revoke_grants(session, tx)
    try:
        await session.commit()
    except IntegrityError:
        # Two deliveries of the same notification racing each other (Apple
        # retries aggressively). The unique index on transaction_id is the
        # arbiter; the loser is the idempotent-replay case, not an error — a
        # 500 here would make Apple retry a revocation that already landed.
        await session.rollback()
        return False, []

    if not revoked_order_ids:
        # Nothing to take back *here*. Two legitimate causes: a subscription
        # (entitlement lives in quiz-agent, granted via RevenueCat) or a pack
        # purchase whose order row never made it. Either way the row above
        # already denies every future use of this transaction in this service,
        # but a human may still need to reconcile the other side — so say so
        # loudly rather than silently returning 200.
        message = (
            "App Store revocation recorded with no local grant to revoke: "
            f"type={notification_type} transaction_id={tx.transaction_id} "
            f"product_id={tx.product_id} — if this is a subscription, verify "
            "quiz-agent's entitlement was revoked by the RevenueCat webhook"
        )
        logger.error(message)
        sentry_sdk.capture_message(message, level="error")

    return True, revoked_order_ids
