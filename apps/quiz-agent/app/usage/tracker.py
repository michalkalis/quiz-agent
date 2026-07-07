"""Persistent usage tracker for freemium question limits (issue #60, task 60.5).

Tracks questions per subject in the ``daily_usage`` Postgres table, so the
count survives server restarts/deploys (the in-memory dict it replaced reset
on every restart, handing out free buckets). One row per (subject, UTC day);
the free quota is a **calendar-month window** (#87): the limit check sums the
subject's daily rows since the 1st of the current UTC month, and the reset is
implicit — a new month simply sums no prior rows. No scan, no cron, and the
per-day granularity is kept (no migration from the daily model).

Public method names are unchanged from the in-memory version, but they are now
``async`` (they do DB I/O). Premium users bypass the limit and are not counted.
"""

from __future__ import annotations

import logging
import os
from datetime import date, datetime, timezone

from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..db.models import DailyUsage

logger = logging.getLogger(__name__)

FREE_MONTHLY_LIMIT = int(os.getenv("FREE_MONTHLY_LIMIT", "100"))


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
        """Check whether ``subject_id`` may ask another question.

        Returns (allowed, remaining, resets_at). Premium → unlimited (-1)."""
        async with self._sessionmaker() as session:
            count, premium = await self._read_month(session, subject_id)
        if premium:
            return True, -1, _next_reset()
        remaining = max(0, self.monthly_limit - count)
        return remaining > 0, remaining, _next_reset()

    async def record_question(self, subject_id: str) -> int:
        """Record a question for ``subject_id``; returns the new monthly count.

        Increments today's row (per-day granularity is kept); premium subjects
        are not counted (matches the prior behavior)."""
        async with self._sessionmaker() as session:
            count, premium = await self._read_month(session, subject_id)
            if premium:
                # Keep a visible row for today, but don't increment.
                await session.execute(
                    pg_insert(DailyUsage)
                    .values(
                        subject_id=subject_id,
                        usage_date=_today(),
                        questions_count=0,
                        is_premium=True,
                    )
                    .on_conflict_do_nothing(index_elements=["subject_id", "usage_date"])
                )
                await session.commit()
                return count

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

    async def get_usage(self, subject_id: str) -> dict:
        """Usage stats for a subject (used by the /usage endpoint)."""
        async with self._sessionmaker() as session:
            count, premium = await self._read_month(session, subject_id)
        resets_at = _next_reset()
        if premium:
            return {
                "user_id": subject_id,
                "is_premium": True,
                "questions_used": count,
                "questions_limit": None,
                "remaining": None,
                "resets_at": resets_at.isoformat(),
            }
        return {
            "user_id": subject_id,
            "is_premium": False,
            "questions_used": count,
            "questions_limit": self.monthly_limit,
            "remaining": max(0, self.monthly_limit - count),
            "resets_at": resets_at.isoformat(),
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
