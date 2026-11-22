"""#205 — daily challenge, sub-task 205.8: extra questions for finishing the day's challenge.

Why: finishing the challenge must feel like a gift every free player notices, so
the 10 extra questions are spent BEFORE the monthly allowance; they die at the
player's local midnight (no stockpiling), an unfinished play grants nothing,
subscribers neither get nor see it, and two parallel questions can never spend
more than the 10. Real Postgres schema (``db_sessionmaker``).
"""

from __future__ import annotations

import asyncio
from datetime import UTC, date, datetime, timedelta

import pytest
from app.daily_challenge import service as daily_service
from app.daily_challenge.service import DailyChallengeService
from app.db.base import utcnow
from app.db.models import DailyChallengePlay, Product, Subscription
from app.usage.tracker import UsageTracker
from sqlalchemy import select

pytestmark = pytest.mark.asyncio

SUBJECT = "anon_bonus_subject"
DAY = date(2026, 11, 22)
NOON = datetime(2026, 11, 22, 12, 0, tzinfo=UTC)


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("RC_ALLOWED_ENVIRONMENT", "PRODUCTION")
    monkeypatch.setenv("DAILY_BONUS_QUESTIONS", "10")


def _tracker(sm, limit=3, now=NOON) -> UsageTracker:
    return UsageTracker(sm, monthly_limit=limit, now=lambda: now)


async def _play(sm, *, finished=True, expires=None, used=0, subject=SUBJECT, day=DAY):
    async with sm() as db:
        db.add(
            DailyChallengePlay(
                subject_id=subject,
                challenge_date=day,
                language="en",
                finished_at=NOON if finished else None,
                bonus_expires_at=expires or NOON + timedelta(hours=12),
                bonus_used=used,
            )
        )
        await db.commit()


async def _plays(sm):
    async with sm() as db:
        return (await db.execute(select(DailyChallengePlay))).scalars().all()


async def _month_count(tracker) -> int:
    return (await tracker.get_usage(SUBJECT))["questions_used"]


async def test_bonus_is_spent_before_the_monthly_counter(db_sessionmaker):
    """The reward is felt only if the first questions after finishing are free
    of the monthly allowance: the monthly count must not move."""
    await _play(db_sessionmaker)
    t = _tracker(db_sessionmaker)
    for _ in range(4):
        await t.record_question(SUBJECT)
    assert await _month_count(t) == 0
    assert (await _plays(db_sessionmaker))[0].bonus_used == 4
    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == 6 + 3  # bonus left + monthly remaining


async def test_eleventh_question_falls_back_to_monthly(db_sessionmaker):
    await _play(db_sessionmaker)
    t = _tracker(db_sessionmaker)
    for _ in range(11):
        await t.record_question(SUBJECT)
    assert (await _plays(db_sessionmaker))[0].bonus_used == 10
    assert await _month_count(t) == 1


async def test_unfinished_play_grants_nothing(db_sessionmaker):
    """Starting is not finishing: no reward for an abandoned challenge."""
    await _play(db_sessionmaker, finished=False)
    t = _tracker(db_sessionmaker)
    await t.record_question(SUBJECT)
    assert await _month_count(t) == 0 + 1
    assert (await _plays(db_sessionmaker))[0].bonus_used == 0


async def test_free_player_at_monthly_limit_allowed_only_with_bonus(db_sessionmaker):
    t = _tracker(db_sessionmaker, limit=1)
    await t.record_question(SUBJECT)
    assert (await t.check_limit(SUBJECT))[0] is False
    await _play(db_sessionmaker)
    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == 10


async def test_expired_bonus_grants_nothing(db_sessionmaker):
    """Midnight kills it: the clock is injected, no sleeping."""
    await _play(db_sessionmaker, expires=NOON + timedelta(hours=1))
    before = _tracker(db_sessionmaker, limit=0)
    assert (await before.check_limit(SUBJECT))[0] is True
    after = _tracker(db_sessionmaker, limit=0, now=NOON + timedelta(hours=1))
    assert (await after.check_limit(SUBJECT))[0] is False
    await after.record_question(SUBJECT)
    assert (await _plays(db_sessionmaker))[0].bonus_used == 0


async def test_entitled_account_never_consumes_the_bonus(db_sessionmaker):
    """Subscribers have their own big allowance; the bonus stays untouched."""
    await _play(db_sessionmaker)
    async with db_sessionmaker() as s:
        s.add(Product(product_id="p", kind="subscription", tier="unlimited"))
        s.add(
            Subscription(
                account_id=SUBJECT,
                product_id="p",
                status="active",
                expires_at=NOON + timedelta(days=30),
                rc_original_txn_id="t1",
                last_event_ts_ms=1,
                environment="PRODUCTION",
            )
        )
        await s.commit()
    t = _tracker(db_sessionmaker)
    await t.record_question(SUBJECT)
    assert (await _plays(db_sessionmaker))[0].bonus_used == 0
    assert await _month_count(t) == 1


async def test_concurrent_records_cannot_overspend(db_sessionmaker):
    """The guarded UPDATE re-checks the budget on the locked row, so 15 parallel
    questions spend exactly 10 bonus and put the other 5 on the monthly count."""
    await _play(db_sessionmaker)
    t = _tracker(db_sessionmaker, limit=50)
    await asyncio.gather(*(t.record_question(SUBJECT) for _ in range(15)))
    assert (await _plays(db_sessionmaker))[0].bonus_used == 10
    assert await _month_count(t) == 5


async def test_reward_off_with_zero(db_sessionmaker, monkeypatch):
    monkeypatch.setenv("DAILY_BONUS_QUESTIONS", "0")
    await _play(db_sessionmaker)
    t = _tracker(db_sessionmaker, limit=1)
    await t.record_question(SUBJECT)
    assert (await _plays(db_sessionmaker))[0].bonus_used == 0
    assert (await t.check_limit(SUBJECT))[0] is False


# ── the play row and the state the app shows ───────────────────────────────
class _Retriever:
    async def daily_candidates(self, language, n=300):
        from tests.test_daily_challenge_service import _q

        return [_q(i) for i in range(12)]

    async def get(self, qid):
        return None

    async def get_translations(self, ids, language, statuses=("approved",)):
        return {}


@pytest.mark.parametrize("offset", [0, 60, -480])
async def test_expiry_is_the_players_local_midnight(db_sessionmaker, offset):
    """+60 (Bratislava) ends an hour earlier in UTC, -480 (Pacific) eight hours later."""
    svc = DailyChallengeService(db_sessionmaker, _Retriever())
    await svc.begin(SUBJECT, "en", DAY, offset)
    expected = datetime(2026, 11, 23, tzinfo=UTC) - timedelta(minutes=offset)
    assert (await _plays(db_sessionmaker))[0].bonus_expires_at == expected


async def test_expiry_defaults_to_utc_and_is_not_rewritten_on_resume(db_sessionmaker):
    svc = DailyChallengeService(db_sessionmaker, _Retriever())
    await svc.begin(SUBJECT, "en", DAY)
    await svc.begin(SUBJECT, "en", DAY, 60)
    assert (await _plays(db_sessionmaker))[0].bonus_expires_at == datetime(
        2026, 11, 23, tzinfo=UTC
    )


async def test_state_fields_before_after_finish_and_after_use(
    db_sessionmaker, monkeypatch
):
    svc = DailyChallengeService(db_sessionmaker, _Retriever())
    monkeypatch.setattr(daily_service, "utcnow", lambda: NOON)
    s0 = await svc.state(SUBJECT, "en", DAY)
    assert (s0.bonus_offer, s0.bonus_left, s0.days_played) == (10, None, 0)

    play, _ = await svc.begin(SUBJECT, "en", DAY)
    s1 = await svc.state(SUBJECT, "en", DAY)
    assert (s1.bonus_offer, s1.bonus_left, s1.days_played) == (10, None, 0)

    async with db_sessionmaker() as db:  # finish it, one older finished play too
        row = (await db.execute(select(DailyChallengePlay))).scalar_one()
        row.finished_at = NOON
        row.bonus_expires_at = NOON + timedelta(hours=5)
        db.add(
            DailyChallengePlay(
                subject_id=SUBJECT,
                challenge_date=DAY - timedelta(days=3),
                language="en",
                finished_at=NOON - timedelta(days=3),
                bonus_expires_at=NOON - timedelta(days=2),
            )
        )
        await db.commit()
    s2 = await svc.state(SUBJECT, "en", DAY)
    assert (s2.status, s2.bonus_left, s2.days_played) == ("played", 10, 2)

    t = _tracker(db_sessionmaker)
    for _ in range(3):
        await t.record_question(SUBJECT)
    assert (await svc.state(SUBJECT, "en", DAY)).bonus_left == 7

    monkeypatch.setattr(daily_service, "utcnow", lambda: NOON + timedelta(hours=6))
    assert (await svc.state(SUBJECT, "en", DAY)).bonus_left == 0


async def test_state_hides_bonus_from_subscribers_and_when_off(
    db_sessionmaker, monkeypatch
):
    svc = DailyChallengeService(db_sessionmaker, _Retriever())
    monkeypatch.setenv("DAILY_BONUS_QUESTIONS", "0")
    assert (await svc.state(SUBJECT, "en", DAY)).bonus_offer is None
    monkeypatch.setenv("DAILY_BONUS_QUESTIONS", "10")
    async with db_sessionmaker() as s:
        s.add(Product(product_id="p", kind="subscription", tier="unlimited"))
        s.add(
            Subscription(
                account_id=SUBJECT,
                product_id="p",
                status="active",
                expires_at=utcnow() + timedelta(days=30),
                rc_original_txn_id="t1",
                last_event_ts_ms=1,
                environment="PRODUCTION",
            )
        )
        await s.commit()
    state = await svc.state(SUBJECT, "en", DAY)
    assert state.bonus_offer is None and state.bonus_left is None
