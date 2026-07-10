"""Server-side entitlement reads for issue #93 (subscription IAP + packs).

The quota gate (``UsageTracker.check_limit`` / ``record_question``) resolves the
serving path **subscription → free allotment → pack credits → deny** (Design §3).
The two entitlement inputs to that decision live here so both the non-mutating
check and the mutating record read one implementation:

* ``account_is_entitled`` — the subscriber is inside an active/grace window
  (``status ∈ {active, grace} AND expires_at > now``). Grace is Apple's
  billing-retry window and still counts as entitled (D-grace / flaw fix 2).
* ``account_credit_balance`` — the consumable pack balance is ``SUM(delta)`` over
  the append-only ``credit_ledger`` (Design §1/§4).

**Hard invariant — DEFAULT-DENY on a null/absent ``account_id``** (preserves the
#89 null-subject bypass fix): no account ⇒ not entitled, zero balance, so a
missing subject can never bypass the gate.

Both functions are **NON-MUTATING** — they only read. The single consume point
stays in ``record_question`` so the codebase's check→record split is intact.
"""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..db.base import utcnow
from ..db.models import CreditLedger, Subscription
from .subscription_state import STATUS_ACTIVE, STATUS_GRACE

# Statuses that count as entitled (D-grace): active OR the billing-retry grace.
_ENTITLED_STATUSES = (STATUS_ACTIVE, STATUS_GRACE)


async def account_is_entitled(
    session: AsyncSession, account_id: str | None, *, now: datetime | None = None
) -> bool:
    """True iff ``account_id`` has an active/grace subscription not yet expired.

    NON-MUTATING. DEFAULT-DENY: a falsy ``account_id`` is never entitled.
    """
    if not account_id:
        return False
    now = now or utcnow()
    row = (
        await session.execute(
            select(Subscription.status, Subscription.expires_at).where(
                Subscription.account_id == account_id
            )
        )
    ).first()
    if row is None:
        return False
    status, expires_at = row
    return status in _ENTITLED_STATUSES and expires_at > now


async def account_credit_balance(session: AsyncSession, account_id: str | None) -> int:
    """Pack-credit balance = ``SUM(credit_ledger.delta)`` for ``account_id``.

    NON-MUTATING. DEFAULT-DENY: a falsy ``account_id`` has zero balance. A
    fully-clawed-back account can read ``<= 0``; the gate treats that as no
    credits (Design §4).
    """
    if not account_id:
        return 0
    balance = (
        await session.execute(
            select(func.coalesce(func.sum(CreditLedger.delta), 0)).where(
                CreditLedger.account_id == account_id
            )
        )
    ).scalar_one()
    return int(balance)


async def account_subscription_status(
    session: AsyncSession, account_id: str | None
) -> str:
    """Raw stored subscription status for display (``/usage``), or ``"none"``.

    NON-MUTATING. Reports the ``subscription.status`` column verbatim (does not
    re-derive expiry — that is ``account_is_entitled``'s job); ``"none"`` when no
    row exists or ``account_id`` is falsy.
    """
    if not account_id:
        return "none"
    status = (
        await session.execute(
            select(Subscription.status).where(Subscription.account_id == account_id)
        )
    ).scalar_one_or_none()
    return status or "none"


class EntitlementService:
    """Sessionmaker-backed wrapper over the entitlement reads (Design §3).

    Opens its own session per call for standalone use; ``UsageTracker`` instead
    calls the module-level functions with its own session so the entitlement
    read composes inside the same transaction as the guarded credit debit.
    """

    def __init__(self, sessionmaker: async_sessionmaker[AsyncSession]) -> None:
        self._sessionmaker = sessionmaker

    async def is_entitled(self, account_id: str | None) -> bool:
        async with self._sessionmaker() as session:
            return await account_is_entitled(session, account_id)

    async def credit_balance(self, account_id: str | None) -> int:
        async with self._sessionmaker() as session:
            return await account_credit_balance(session, account_id)
