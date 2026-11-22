"""Persistent usage tracker for freemium question limits (issue #60, task 60.5).

Tracks questions per subject in the ``daily_usage`` Postgres table, so the
count survives server restarts/deploys (the in-memory dict it replaced reset
on every restart, handing out free buckets). One row per (subject, UTC day);
the free quota is a **calendar-month window** (#87): the limit check sums the
subject's daily rows since the 1st of the current UTC month, and the reset is
implicit — a new month simply sums no prior rows. No scan, no cron, and the
per-day granularity is kept (no migration from the daily model).

Public method names are unchanged from the in-memory version, but they are now
``async`` (they do DB I/O). Issue #93 layered entitlement on top; #199 made the
subscription a capped plan (Trubbo Plus, 1,000 questions a month) instead of an
unlimited bypass: the gate resolves the monthly allowance (subscriber or free
limit, one shared counter) → pack credits → deny (see ``check_limit`` /
``record_question``); the legacy ``daily_usage.is_premium`` column is no longer
read by the gate (Design §5), only surfaced by ``get_usage``.
"""

from __future__ import annotations

import logging
import os
from datetime import date, datetime, timezone
from collections.abc import Callable
from dataclasses import dataclass

import uuid

from sqlalchemy import func, insert, literal, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..config import get_settings
from ..db.models import CreditLedger, DailyChallengePlay, DailyUsage
from ..shared_quiz.store import person_ids
from .entitlement import (
    account_credit_balance,
    account_is_entitled,
    account_subscription_status,
)
from . import voice_allowance

logger = logging.getLogger(__name__)

FREE_MONTHLY_LIMIT = int(os.getenv("FREE_MONTHLY_LIMIT", "150"))
# Founder experiment 2026-11-21: of the free questions, at most this many may be
# answered by voice (the transcription is the cost); see ``voice_allowance``.
FREE_MONTHLY_VOICE_LIMIT = int(os.getenv("FREE_MONTHLY_VOICE_LIMIT", "30"))
# #199: Trubbo Plus (the monthly subscription) is a fixed allowance, not unlimited.
SUBSCRIBER_MONTHLY_LIMIT = int(os.getenv("SUBSCRIBER_MONTHLY_LIMIT", "1000"))


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _today(now: datetime | None = None) -> date:
    return (now or _utcnow()).date()


def _month_start(now: datetime | None = None) -> date:
    return _today(now).replace(day=1)


@dataclass(frozen=True)
class VoiceCheck:
    """``limit`` None = this account's voice answers are not limited."""

    allowed: bool
    used: int
    limit: int | None
    resets_at: datetime


def _next_reset(now: datetime | None = None) -> datetime:
    """Midnight UTC on the 1st of the month after ``now``."""
    now = now or _utcnow()
    if now.month == 12:
        return datetime(now.year + 1, 1, 1, tzinfo=timezone.utc)
    return datetime(now.year, now.month + 1, 1, tzinfo=timezone.utc)


class UsageTracker:
    """Persistent per-subject monthly question usage, backed by ``daily_usage``."""

    def __init__(
        self,
        sessionmaker: async_sessionmaker[AsyncSession],
        monthly_limit: int = FREE_MONTHLY_LIMIT,
        now: Callable[[], datetime] | None = None,
        subscriber_monthly_limit: int = SUBSCRIBER_MONTHLY_LIMIT,
        voice_monthly_limit: int = FREE_MONTHLY_VOICE_LIMIT,
    ) -> None:
        self._sessionmaker = sessionmaker
        self.monthly_limit = monthly_limit
        self.subscriber_monthly_limit = subscriber_monthly_limit
        self.voice_monthly_limit = voice_monthly_limit
        # #180 track C: the ONE time source for the quota gate. Each public call
        # reads it once and threads that instant through the month window, the
        # subscription expiry check and ``resets_at`` — so a request straddling
        # the monthly boundary can't count a question into one month and report
        # the reset of another. Tests inject a fake to drive the rollover;
        # ``None`` resolves to the module's ``_utcnow`` at call time.
        self._injected_now = now

    def _now(self) -> datetime:
        return self._injected_now() if self._injected_now else _utcnow()

    def _limit_for(self, entitled: bool) -> int:
        """The monthly allowance that applies right now. There is ONE counter
        per account, so a subscription lapsing mid-month swaps the 1,000 limit
        for the free one against the same count (intended, #199)."""
        return self.subscriber_monthly_limit if entitled else self.monthly_limit

    async def _read_month(
        self, session: AsyncSession, subject_id: str, now: datetime
    ) -> tuple[int, bool]:
        """Return (questions_count, is_premium) for the calendar month of ``now``.

        The count sums the subject's daily rows since the 1st of the month.
        Premium comes from the subject's most recent row regardless of month,
        so premium persists across the monthly reset."""
        count = (
            await session.execute(
                select(func.coalesce(func.sum(DailyUsage.questions_count), 0)).where(
                    DailyUsage.subject_id == subject_id,
                    DailyUsage.usage_date >= _month_start(now),
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

    @staticmethod
    def _active_bonus(ids: list[str], now: datetime, offer: int) -> list:
        """WHERE clauses of a usable daily-challenge bonus (205.8): a FINISHED
        play of this person, not yet past their local midnight, not spent."""
        return [
            DailyChallengePlay.subject_id.in_(ids),
            DailyChallengePlay.finished_at.is_not(None),
            DailyChallengePlay.bonus_expires_at > now,
            DailyChallengePlay.bonus_used < offer,
        ]

    async def _bonus_left(
        self, session: AsyncSession, subject_id: str, now: datetime
    ) -> int:
        offer = get_settings().daily_bonus_questions
        if offer <= 0:
            return 0
        ids = await person_ids(session, subject_id)
        used = (
            await session.execute(
                select(func.max(DailyChallengePlay.bonus_used)).where(
                    *self._active_bonus(ids, now, offer)
                )
            )
        ).scalar_one_or_none()
        return 0 if used is None else offer - int(used)

    async def _spend_bonus(
        self, session: AsyncSession, subject_id: str, now: datetime
    ) -> bool:
        """One guarded UPDATE: the bonus condition is re-checked on the row
        under its lock, so two concurrent records cannot overspend it."""
        offer = get_settings().daily_bonus_questions
        if offer <= 0:
            return False
        ids = await person_ids(session, subject_id)
        active = self._active_bonus(ids, now, offer)
        pick = (
            select(DailyChallengePlay.id)
            .where(*active)
            .order_by(DailyChallengePlay.challenge_date.desc())
            .limit(1)
            .scalar_subquery()
        )
        spent = await session.execute(
            update(DailyChallengePlay)
            .where(DailyChallengePlay.id == pick, *active)
            .values(bonus_used=DailyChallengePlay.bonus_used + 1)
            .returning(DailyChallengePlay.id)
        )
        return spent.first() is not None

    async def check_limit(self, subject_id: str) -> tuple[bool, int, datetime]:
        """Check whether ``subject_id`` may ask another question — NON-MUTATING.

        Resolves the serving path in strict order (Design §3, issue #93; #199)
        and performs **no writes**:

        1. Monthly allowance: monthly count < the applicable limit → allow,
           allowance remaining. The limit is ``subscriber_monthly_limit`` for an
           entitled account (``status ∈ {active, grace} AND expires_at>now``;
           grace = Apple's billing-retry window, flaw fix 2) else
           ``monthly_limit``. Both draw on the same monthly counter.
        2. Pack credits: ``SUM(credit_ledger.delta) > 0`` → allow, balance as
           remaining.
        3. Else deny.

        Returns ``(allowed, remaining, resets_at)`` (unchanged signature).
        ``daily_usage.is_premium`` is no longer read — entitlement comes solely
        from the ``subscription`` table (default-deny on a null account)."""
        now = self._now()
        async with self._sessionmaker() as session:
            entitled = await account_is_entitled(session, subject_id, now=now)
            count, _ = await self._read_month(session, subject_id, now)
            remaining = max(0, self._limit_for(entitled) - count)
            if not entitled:
                bonus = await self._bonus_left(session, subject_id, now)
                if bonus > 0:
                    return True, bonus + remaining, _next_reset(now)
            if remaining > 0:
                return True, remaining, _next_reset(now)
            balance = await account_credit_balance(session, subject_id)
            if balance > 0:
                return True, balance, _next_reset(now)
        return False, 0, _next_reset(now)

    async def record_question(self, subject_id: str) -> int:
        """Record one *served* question for ``subject_id`` — the single consume
        point (MUTATING). Returns the monthly count after the effect.

        Re-derives the same order as :meth:`check_limit` independently (so a
        check→record race can't double-spend — #90 TOCTOU) and applies EXACTLY
        ONE effect (Design §3):

        * Under the applicable monthly limit (subscriber limit if entitled, else
          the free limit) → the atomic monthly-counter upsert.
        * Else → a single guarded credit debit
          (``INSERT … SELECT … WHERE (SELECT SUM(delta)…) > 0``), so a fully-spent
          balance debits nothing.

        Because the debit is one guarded write and the path is re-derived here,
        a pre-record 500 (question retrieval, ``quiz.py:96``) debits nothing."""
        now = self._now()
        async with self._sessionmaker() as session:
            entitled = await account_is_entitled(session, subject_id, now=now)
            count, _ = await self._read_month(session, subject_id, now)
            if not entitled and await self._spend_bonus(session, subject_id, now):
                # 205.8: the daily-challenge bonus is spent first; the monthly
                # counter and credits stay untouched.
                await session.commit()
                return count
            limit = self._limit_for(entitled)
            if count < limit:
                stmt = (
                    pg_insert(DailyUsage)
                    .values(
                        subject_id=subject_id,
                        usage_date=_today(now),
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
                    limit,
                )
                return new_count

            # Pack-credit path: one serialized guarded debit.
            await self._debit_one_credit(session, subject_id)
            await session.commit()
            return count

    async def check_voice_answer(self, subject_id: str, key: str) -> VoiceCheck:
        """May ``subject_id`` answer by voice — NON-MUTATING (``voice_allowance``).
        A free player past the voice limit is still allowed the answer it was
        already charged for (``key``), so a retry is never refused."""
        now = self._now()
        async with self._sessionmaker() as session:
            used = await voice_allowance.voice_answers_since(
                session, subject_id, _month_start(now)
            )
            if not await voice_allowance.voice_is_limited(session, subject_id, now):
                return VoiceCheck(True, used, None, _next_reset(now))
            limit = self.voice_monthly_limit
            allowed = used < limit or await voice_allowance.already_charged(
                session, subject_id, key
            )
        return VoiceCheck(allowed, used, limit, _next_reset(now))

    async def record_voice_answer(self, subject_id: str, key: str) -> bool:
        """Count one transcribed voice answer, once per ``key`` (MUTATING).
        Counted for every plan, so a lapsing subscription meets a true count."""
        now = self._now()
        try:
            async with self._sessionmaker() as session:
                charged = await voice_allowance.charge(
                    session, subject_id, key, _today(now)
                )
                await session.commit()
            return charged
        except Exception as exc:  # noqa: BLE001
            # Fail open, like the daily caps: the answer is already transcribed
            # and the player is waiting for its verdict; a counter that cannot
            # be written must not turn it into an error (it costs one count).
            logger.warning("Voice answer not counted: %s", type(exc).__name__)
            return False

    async def tts_chars_today(self, subject_id: str) -> int:
        """Characters this subject has had billed to the TTS primary today (UTC)."""
        async with self._sessionmaker() as session:
            used = (
                await session.execute(
                    select(DailyUsage.tts_chars).where(
                        DailyUsage.subject_id == subject_id,
                        DailyUsage.usage_date == _today(self._now()),
                    )
                )
            ).scalar_one_or_none()
        return int(used or 0)

    async def add_tts_chars(self, subject_id: str, chars: int) -> None:
        """Atomically add billed TTS characters to today's row (#193.13)."""
        async with self._sessionmaker() as session:
            await session.execute(
                pg_insert(DailyUsage)
                .values(
                    subject_id=subject_id,
                    usage_date=_today(self._now()),
                    questions_count=0,
                    tts_chars=chars,
                )
                .on_conflict_do_update(
                    index_elements=["subject_id", "usage_date"],
                    set_={"tts_chars": DailyUsage.tts_chars + chars},
                )
            )
            await session.commit()

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
        are unchanged. #199: an entitled account (Trubbo Plus) reports its real
        monthly limit and remaining, like the free tier does; ``plan`` is
        ``"plus"`` for it, else ``"free"`` (the 429 / analytics sites read it).
        Only the legacy ``is_premium`` flag on a NON-entitled account still
        reports unlimited (``None``), as before. 2026-11-21 adds the free voice
        allowance: ``voice_answers_used`` / ``_limit`` / ``_remaining``."""
        now = self._now()
        async with self._sessionmaker() as session:
            count, premium = await self._read_month(session, subject_id, now)
            entitled = await account_is_entitled(session, subject_id, now=now)
            credit_balance = await account_credit_balance(session, subject_id)
            subscription_status = await account_subscription_status(session, subject_id)
            voice_used = await voice_allowance.voice_answers_since(
                session, subject_id, _month_start(now)
            )
        resets_at = _next_reset(now)
        plan = "plus" if entitled else "free"
        # The same rule as the gate: only a free player without pack credits
        # has a voice limit (null = not limited).
        voice_limit = (
            self.voice_monthly_limit if not entitled and credit_balance <= 0 else None
        )
        voice = {
            "voice_answers_used": voice_used,
            "voice_answers_limit": voice_limit,
            "voice_answers_remaining": (
                None if voice_limit is None else max(0, voice_limit - voice_used)
            ),
        }
        if premium and not entitled:
            return {
                "user_id": subject_id,
                "is_premium": premium,
                "questions_used": count,
                "questions_limit": None,
                "remaining": None,
                "resets_at": resets_at.isoformat(),
                "subscription_status": subscription_status,
                "credit_balance": credit_balance,
                "plan": plan,
                **voice,
            }
        limit = self._limit_for(entitled)
        return {
            "user_id": subject_id,
            "is_premium": premium,
            "questions_used": count,
            "questions_limit": limit,
            "remaining": max(0, limit - count),
            "resets_at": resets_at.isoformat(),
            "subscription_status": subscription_status,
            "credit_balance": credit_balance,
            "plan": plan,
            **voice,
        }

    async def set_premium(self, subject_id: str, is_premium: bool = True) -> None:
        """Set premium for a subject (admin-only path). Upserts today's row;
        later reads inherit it via the latest-row lookup in ``_read_month``."""
        async with self._sessionmaker() as session:
            await session.execute(
                pg_insert(DailyUsage)
                .values(
                    subject_id=subject_id,
                    usage_date=_today(self._now()),
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
            _, premium = await self._read_month(session, subject_id, self._now())
        return premium
