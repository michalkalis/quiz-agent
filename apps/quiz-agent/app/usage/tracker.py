"""Persistent usage tracker for freemium question limits (issue #60, task 60.5).

Tracks questions per subject in the ``daily_usage`` Postgres table, so the
count survives server restarts/deploys (the in-memory dict it replaced reset
on every restart, handing out free buckets). One row per (subject, UTC day);
the free quota is a **calendar-month window** (#87): the limit check sums the
subject's daily rows since the 1st of the current UTC month, and the reset is
implicit — a new month simply sums no prior rows. No scan, no cron, and the
per-day granularity is kept (no migration from the daily model).

Public method names are unchanged from the in-memory version, but they are now
``async`` (they do DB I/O). Issue #93 layered entitlement on top: the gate now
resolves subscription → free allotment → pack credits → deny (see
``check_limit`` / ``record_question``); the legacy ``daily_usage.is_premium``
column is no longer read by the gate (Design §5), only surfaced by ``get_usage``.
"""

from __future__ import annotations

import logging
import os
from datetime import date, datetime, timezone

import uuid

from sqlalchemy import func, insert, literal, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..db.models import CreditLedger, DailyUsage
from .entitlement import (
    account_credit_balance,
    account_is_entitled,
    account_subscription_status,
)

logger = logging.getLogger(__name__)

FREE_MONTHLY_LIMIT = int(os.getenv("FREE_MONTHLY_LIMIT", "30"))


def _today() -> date:
    return datetime.now(timezone.utc).date()


def _month_start() -> date:
    return _today().replace(day=1)


def _next_reset() -> datetime:
    """Midnight UTC on the 1st of the next month."""
    now = datetime.now(timezone.utc)
    if now.month == 12:
        return datetime(now.year + 1, 1, 1, tzinfo=timezone.utc)
    return datetime(now.year, now.month + 1, 1, tzinfo=timezone.utc)


class UsageTracker:
    """Persistent per-subject monthly question usage, backed by ``daily_usage``."""

    def __init__(
        self,
        sessionmaker: async_sessionmaker[AsyncSession],
        monthly_limit: int = FREE_MONTHLY_LIMIT,
    ) -> None:
        self._sessionmaker = sessionmaker
        self.monthly_limit = monthly_limit

    async def _read_month(
        self, session: AsyncSession, subject_id: str
    ) -> tuple[int, bool]:
        """Return (questions_count, is_premium) for the current calendar month.

        The count sums the subject's daily rows since the 1st of the month.
        Premium comes from the subject's most recent row regardless of month,
        so premium persists across the monthly reset."""
        count = (
            await session.execute(
                select(func.coalesce(func.sum(DailyUsage.questions_count), 0)).where(
                    DailyUsage.subject_id == subject_id,
                    DailyUsage.usage_date >= _month_start(),
                )
            )
        ).scalar_one()

        premium = (
            await session.execute(
                select(DailyUsage.is_premium)
                .where(DailyUsage.subject_id == subject_id)
                .order_by(DailyUsage.usage_date.desc())
                .limit(1)
            )
        ).scalar_one_or_none()
        return int(count), bool(premium)

    async def check_limit(self, subject_id: str) -> tuple[bool, int, datetime]:
        """Check whether ``subject_id`` may ask another question — NON-MUTATING.

        Resolves the serving path in strict order (Design §3, issue #93) and
        performs **no writes**:

        1. Entitled subscription (``status ∈ {active, grace} AND expires_at>now``)
           → allow, unlimited (``-1``). Grace = Apple's billing-retry window
           (flaw fix 2); it must not fall through to the free allotment.
        2. Free allotment: monthly count < ``monthly_limit`` → allow, free
           remaining.
        3. Pack credits: ``SUM(credit_ledger.delta) > 0`` → allow, balance as
           remaining.
        4. Else deny.

        Returns ``(allowed, remaining, resets_at)`` (unchanged signature).
        ``daily_usage.is_premium`` is no longer read — entitlement comes solely
        from the ``subscription`` table (default-deny on a null account)."""
        async with self._sessionmaker() as session:
            if await account_is_entitled(session, subject_id):
                return True, -1, _next_reset()
            count, _ = await self._read_month(session, subject_id)
            remaining = max(0, self.monthly_limit - count)
            if remaining > 0:
                return True, remaining, _next_reset()
            balance = await account_credit_balance(session, subject_id)
            if balance > 0:
                return True, balance, _next_reset()
        return False, 0, _next_reset()

    async def record_question(self, subject_id: str) -> int:
        """Record one *served* question for ``subject_id`` — the single consume
        point (MUTATING). Returns the monthly free count after the effect.

        Re-derives the same order as :meth:`check_limit` independently (so a
        check→record race can't double-spend — #90 TOCTOU) and applies EXACTLY
        ONE effect (Design §3):

        * Entitled → insert the visible daily row only, no counter increment,
          no debit (unlimited).
        * Free (count < limit) → the atomic monthly-counter upsert (unchanged).
        * Else → a single guarded credit debit
          (``INSERT … SELECT … WHERE (SELECT SUM(delta)…) > 0``), so a fully-spent
          balance debits nothing.

        Because the debit is one guarded write and the path is re-derived here,
        a pre-record 500 (question retrieval, ``quiz.py:96``) debits nothing."""
        async with self._sessionmaker() as session:
            if await account_is_entitled(session, subject_id):
                count, _ = await self._read_month(session, subject_id)
                # Keep a visible row for today, but don't increment or debit.
                await session.execute(
                    pg_insert(DailyUsage)
                    .values(
                        subject_id=subject_id,
                        usage_date=_today(),
                        questions_count=0,
                        is_premium=False,
                    )
                    .on_conflict_do_nothing(index_elements=["subject_id", "usage_date"])
                )
                await session.commit()
                return count

            count, _ = await self._read_month(session, subject_id)
            if count < self.monthly_limit:
                stmt = (
                    pg_insert(DailyUsage)
                    .values(
                        subject_id=subject_id,
                        usage_date=_today(),
                        questions_count=1,
                        is_premium=False,
                    )
                    .on_conflict_do_update(
                        index_elements=["subject_id", "usage_date"],
                        set_={"questions_count": DailyUsage.questions_count + 1},
                    )
                )
                await session.execute(stmt)
                await session.commit()
                new_count = count + 1
                logger.debug(
                    "Usage: subject=%s questions_this_month=%d limit=%d",
                    subject_id,
                    new_count,
                    self.monthly_limit,
                )
                return new_count

            # Pack-credit path: one serialized guarded debit.
            await self._debit_one_credit(session, subject_id)
            await session.commit()
            return count

    async def _debit_one_credit(self, session: AsyncSession, subject_id: str) -> None:
        """Serialized guarded credit debit on the CALLER's session — no commit.

        The WHERE guard alone is NOT atomic under READ COMMITTED: two concurrent
        debits on separate connections each take a fresh snapshot at their
        statement start, neither sees the other's uncommitted -1, so both guards
        read the same positive balance and both insert — driving a balance of 1
        to -1 (#90 double-spend of the last credit). We serialize the debit per
        account with a transaction-scoped advisory lock held to COMMIT: a second
        concurrent debit blocks on the lock until the first commits, then its
        guard re-reads the now-committed balance and correctly inserts nothing
        when the balance is spent. ``hashtext`` maps the ``account_id`` to the
        lock's integer key.

        Extracted so the concurrency invariant is testable at the exact
        transaction boundary (see ``test_no_double_spend_concurrent``). The lock
        + guarded insert are Postgres-only, same as the ``pg_insert`` upserts in
        :meth:`record_question` — the usage engine is always Postgres.
        """
        await session.execute(
            select(func.pg_advisory_xact_lock(func.hashtext(subject_id)))
        )
        balance_guard = (
            select(func.coalesce(func.sum(CreditLedger.delta), 0))
            .where(CreditLedger.account_id == subject_id)
            .scalar_subquery()
        )
        debit = select(
            literal(uuid.uuid4()),
            literal(subject_id),
            literal(-1),
            literal("consume"),
            literal("question"),
            func.now(),
        ).where(balance_guard > 0)
        await session.execute(
            insert(CreditLedger).from_select(
                ["id", "account_id", "delta", "kind", "reason", "created_at"],
                debit,
            )
        )

    async def get_usage(self, subject_id: str) -> dict:
        """Usage stats for a subject (used by the /usage endpoint).

        Additive per issue #93: adds ``subscription_status`` (raw stored status
        or ``"none"``) and ``credit_balance`` (``SUM(delta)``); the legacy fields
        are unchanged. "Unlimited" display now follows real entitlement (an
        active/grace subscription) OR the legacy ``is_premium`` column, so a real
        subscriber shows unlimited even though the gate no longer reads the
        column."""
        async with self._sessionmaker() as session:
            count, premium = await self._read_month(session, subject_id)
            entitled = await account_is_entitled(session, subject_id)
            credit_balance = await account_credit_balance(session, subject_id)
            subscription_status = await account_subscription_status(session, subject_id)
        resets_at = _next_reset()
        if premium or entitled:
            return {
                "user_id": subject_id,
                "is_premium": premium,
                "questions_used": count,
                "questions_limit": None,
                "remaining": None,
                "resets_at": resets_at.isoformat(),
                "subscription_status": subscription_status,
                "credit_balance": credit_balance,
            }
        return {
            "user_id": subject_id,
            "is_premium": False,
            "questions_used": count,
            "questions_limit": self.monthly_limit,
            "remaining": max(0, self.monthly_limit - count),
            "resets_at": resets_at.isoformat(),
            "subscription_status": subscription_status,
            "credit_balance": credit_balance,
        }

    async def set_premium(self, subject_id: str, is_premium: bool = True) -> None:
        """Set premium for a subject (admin-only path). Upserts today's row;
        later reads inherit it via the latest-row lookup in ``_read_month``."""
        async with self._sessionmaker() as session:
            await session.execute(
                pg_insert(DailyUsage)
                .values(
                    subject_id=subject_id,
                    usage_date=_today(),
                    questions_count=0,
                    is_premium=is_premium,
                )
                .on_conflict_do_update(
                    index_elements=["subject_id", "usage_date"],
                    set_={"is_premium": is_premium},
                )
            )
            await session.commit()
        logger.info("Premium status: subject=%s is_premium=%s", subject_id, is_premium)

    async def is_premium(self, subject_id: str) -> bool:
        async with self._sessionmaker() as session:
            _, premium = await self._read_month(session, subject_id)
        return premium
