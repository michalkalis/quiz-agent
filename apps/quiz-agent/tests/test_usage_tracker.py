"""Tests for the persistent UsageTracker (issue #60, task 60.5).

The point of this task is that the freemium count can no longer be reset by
restarting the server. So the load-bearing test re-instantiates the tracker on
the same DB and asserts the count survives. The rest pin the limit, premium
bypass, the implicit daily reset, and cross-day premium carry-forward.
"""

from __future__ import annotations

from datetime import timedelta

import pytest
from sqlalchemy import select

from app.db.models import DailyUsage
from app.usage.tracker import UsageTracker, _today

pytestmark = pytest.mark.asyncio

SUBJECT = "anon_usage_subject"


def _tracker(sessionmaker, limit=3) -> UsageTracker:
    return UsageTracker(sessionmaker, daily_limit=limit)


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


async def test_yesterdays_count_does_not_count_today(db_sessionmaker):
    """The daily reset is implicit (one row per UTC day): a maxed-out row for
    yesterday must leave today's bucket full."""
    async with db_sessionmaker() as s:
        s.add(
            DailyUsage(
                subject_id=SUBJECT,
                usage_date=_today() - timedelta(days=1),
                questions_count=99,
                is_premium=False,
            )
        )
        await s.commit()

    t = _tracker(db_sessionmaker, limit=3)
    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == 3


async def test_premium_carries_forward_across_days(db_sessionmaker):
    """A subject made premium on a prior day stays premium today (premium is a
    subscription, not a per-day flag)."""
    async with db_sessionmaker() as s:
        s.add(
            DailyUsage(
                subject_id=SUBJECT,
                usage_date=_today() - timedelta(days=2),
                questions_count=0,
                is_premium=True,
            )
        )
        await s.commit()

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
