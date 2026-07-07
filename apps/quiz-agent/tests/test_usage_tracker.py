"""Tests for the persistent UsageTracker (issue #60 task 60.5; monthly window #87).

The point of the persistence is that the freemium count can no longer be reset
by restarting the server. So the load-bearing test re-instantiates the tracker
on the same DB and asserts the count survives. The rest pin the limit, premium
bypass, and the calendar-month window (#87): usage accumulates across days
within the month, last month's rows don't count, and the reset lands on the
1st of the next month.
"""

from __future__ import annotations

from datetime import timedelta

import pytest
from sqlalchemy import select

from app.db.models import DailyUsage
from app.usage.tracker import UsageTracker, _month_start, _today

pytestmark = pytest.mark.asyncio

SUBJECT = "anon_usage_subject"


def _tracker(sessionmaker, limit=3) -> UsageTracker:
    return UsageTracker(sessionmaker, monthly_limit=limit)


async def _seed_row(db_sessionmaker, usage_date, count=0, premium=False):
    async with db_sessionmaker() as s:
        s.add(
            DailyUsage(
                subject_id=SUBJECT,
                usage_date=usage_date,
                questions_count=count,
                is_premium=premium,
            )
        )
        await s.commit()


async def test_count_survives_tracker_reinstantiation(db_sessionmaker):
    """Persistence is the whole point: a fresh tracker (≈ server restart) on the
    same DB must see the already-recorded count, not a fresh zero bucket."""
    t1 = _tracker(db_sessionmaker)
    await t1.record_question(SUBJECT)
    await t1.record_question(SUBJECT)

    t2 = _tracker(db_sessionmaker)  # simulate restart
    usage = await t2.get_usage(SUBJECT)
    assert usage["questions_used"] == 2


async def test_limit_blocks_after_quota(db_sessionmaker):
    t = _tracker(db_sessionmaker, limit=2)
    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == 2

    await t.record_question(SUBJECT)
    await t.record_question(SUBJECT)

    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert not allowed and remaining == 0


async def test_premium_bypasses_limit_and_is_not_counted(db_sessionmaker):
    t = _tracker(db_sessionmaker, limit=1)
    await t.set_premium(SUBJECT, True)

    # Premium recording must not increment the count.
    await t.record_question(SUBJECT)
    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == -1

    usage = await t.get_usage(SUBJECT)
    assert usage["is_premium"] is True
    assert usage["questions_used"] == 0
    assert usage["questions_limit"] is None


async def test_earlier_days_in_month_count_toward_quota(db_sessionmaker):
    """The quota is a monthly pool (#87), not per-day: usage recorded earlier in
    the same calendar month must eat into today's allowance."""
    await _seed_row(db_sessionmaker, _month_start(), count=2)

    t = _tracker(db_sessionmaker, limit=3)
    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == 1

    # Recording today returns the *monthly* total, not today's row count.
    assert await t.record_question(SUBJECT) == 3
    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert not allowed and remaining == 0


async def test_last_months_count_does_not_count(db_sessionmaker):
    """The monthly reset is implicit: a maxed-out row from last month must
    leave this month's pool full."""
    await _seed_row(db_sessionmaker, _month_start() - timedelta(days=1), count=99)

    t = _tracker(db_sessionmaker, limit=3)
    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == 3


async def test_resets_at_is_first_of_next_month(db_sessionmaker):
    """The client shows a reset countdown (#87) — resets_at must be midnight
    UTC on the 1st of the next month, in the future."""
    t = _tracker(db_sessionmaker)
    _, _, resets_at = await t.check_limit(SUBJECT)
    assert resets_at.day == 1
    assert (resets_at.hour, resets_at.minute) == (0, 0)
    assert resets_at.date() > _today()
    assert (resets_at.date() - _today()) <= timedelta(days=31)


async def test_premium_carries_forward_across_days(db_sessionmaker):
    """A subject made premium on a prior day stays premium today (premium is a
    subscription, not a per-day flag) — even across the monthly reset."""
    await _seed_row(db_sessionmaker, _today() - timedelta(days=40), premium=True)

    t = _tracker(db_sessionmaker, limit=1)
    assert await t.is_premium(SUBJECT) is True
    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == -1


async def test_record_question_returns_new_count(db_sessionmaker):
    t = _tracker(db_sessionmaker, limit=10)
    assert await t.record_question(SUBJECT) == 1
    assert await t.record_question(SUBJECT) == 2

    async with db_sessionmaker() as s:
        row = (
            await s.execute(
                select(DailyUsage).where(
                    DailyUsage.subject_id == SUBJECT,
                    DailyUsage.usage_date == _today(),
                )
            )
        ).scalar_one()
    assert row.questions_count == 2
