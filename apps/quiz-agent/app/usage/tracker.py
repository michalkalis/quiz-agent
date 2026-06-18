"""Persistent usage tracker for freemium question limits (issue #60, task 60.5).

Tracks questions-per-day per subject in the ``daily_usage`` Postgres table, so
the count survives server restarts/deploys (the in-memory dict it replaced reset
on every restart, handing out free buckets). One row per (subject, UTC day):
a new day simply has no row yet, so the daily reset is implicit — no scan, no
cron. Premium is carried forward across days so a premium subject stays premium.

Public method names are unchanged from the in-memory version, but they are now
``async`` (they do DB I/O). Premium users bypass the limit and are not counted.
"""

from __future__ import annotations

import logging
import os
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..db.models import DailyUsage

logger = logging.getLogger(__name__)

FREE_DAILY_LIMIT = int(os.getenv("FREE_DAILY_LIMIT", "20"))


def _today() -> date:
    return datetime.now(timezone.utc).date()


def _next_reset() -> datetime:
    """Next midnight UTC."""
    now = datetime.now(timezone.utc)
    return datetime(now.year, now.month, now.day, tzinfo=timezone.utc) + timedelta(
        days=1
    )


class UsageTracker:
    """Persistent per-subject daily question usage, backed by ``daily_usage``."""

    def __init__(
        self,
        sessionmaker: async_sessionmaker[AsyncSession],
        daily_limit: int = FREE_DAILY_LIMIT,
    ) -> None:
        self._sessionmaker = sessionmaker
        self.daily_limit = daily_limit

    async def _read_today(
        self, session: AsyncSession, subject_id: str
    ) -> tuple[int, bool]:
        """Return (questions_count, is_premium) for today without creating a row.

        If there is no row for today, the count is 0 and premium is inherited
        from the subject's most recent prior row (so premium persists across the
        daily reset)."""
        row = (
            await session.execute(
                select(DailyUsage).where(
                    DailyUsage.subject_id == subject_id,
                    DailyUsage.usage_date == _today(),
                )
            )
        ).scalar_one_or_none()
        if row is not None:
            return row.questions_count, row.is_premium

        premium = (
            await session.execute(
                select(DailyUsage.is_premium)
                .where(DailyUsage.subject_id == subject_id)
                .order_by(DailyUsage.usage_date.desc())
                .limit(1)
            )
        ).scalar_one_or_none()
        return 0, bool(premium)

    async def check_limit(self, subject_id: str) -> tuple[bool, int, datetime]:
        """Check whether ``subject_id`` may ask another question.

        Returns (allowed, remaining, resets_at). Premium → unlimited (-1)."""
        async with self._sessionmaker() as session:
            count, premium = await self._read_today(session, subject_id)
        if premium:
            return True, -1, _next_reset()
        remaining = max(0, self.daily_limit - count)
        return remaining > 0, remaining, _next_reset()

    async def record_question(self, subject_id: str) -> int:
        """Record a question for ``subject_id``; returns the new daily count.

        Premium subjects are not counted (matches the prior behavior)."""
        async with self._sessionmaker() as session:
            count, premium = await self._read_today(session, subject_id)
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
                .returning(DailyUsage.questions_count)
            )
            new_count = (await session.execute(stmt)).scalar_one()
            await session.commit()
            logger.debug(
                "Usage: subject=%s questions_today=%d limit=%d",
                subject_id,
                new_count,
                self.daily_limit,
            )
            return new_count

    async def get_usage(self, subject_id: str) -> dict:
        """Usage stats for a subject (used by the /usage endpoint)."""
        async with self._sessionmaker() as session:
            count, premium = await self._read_today(session, subject_id)
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
            "questions_limit": self.daily_limit,
            "remaining": max(0, self.daily_limit - count),
            "resets_at": resets_at.isoformat(),
        }

    async def set_premium(self, subject_id: str, is_premium: bool = True) -> None:
        """Set premium for a subject (admin-only path). Upserts today's row;
        future days inherit it via the carry-forward in ``_read_today``."""
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
            _, premium = await self._read_today(session, subject_id)
        return premium
