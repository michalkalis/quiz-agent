"""Trubbo Plus monthly cap tests (#199).

The monthly subscription stopped being "unlimited": it is 1,000 questions per
calendar month (UTC), drawn from the SAME monthly counter the free tier uses,
and past it the account behaves exactly like a free one at its wall: pack
credits are spent automatically, then the 429 paywall with a pack offer.

Each test says WHY the behaviour matters; the pure free-tier and pack mechanics
stay covered in ``test_usage_tracker`` / ``test_entitlement``.

DB-backed (``TEST_DATABASE_URL``, see ``conftest.py``).
"""

from __future__ import annotations

from datetime import UTC, date, datetime
from typing import ClassVar
from unittest.mock import AsyncMock, MagicMock

import pytest
from app.analytics.recorder import AnalyticsRecorder
from app.analytics.taxonomy import SERVER_EVENTS, clean_properties
from app.api.deps import StartQuizRequest
from app.api.routes.quiz import start_quiz
from app.auth.identity import AuthSubject
from app.quiz.flow import QuizFlowService
from app.session.manager import SessionManager
from app.usage.tracker import (
    FREE_MONTHLY_LIMIT,
    SUBSCRIBER_MONTHLY_LIMIT,
    UsageTracker,
)
from fastapi import HTTPException
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

from tests.test_entitlement import (
    SUBJECT,
    _consume_row_count,
    _ledger_balance,
    _seed_credit,
    _seed_daily,
    _seed_subscription,
)

pytestmark = pytest.mark.asyncio

# A fixed instant inside one month, so the subscription's expiry and the
# monthly window are deterministic instead of depending on the wall clock.
_MID_MONTH = datetime(2026, 10, 15, 12, 0, tzinfo=UTC)
_MONTH_START = date(2026, 10, 1)


@pytest.fixture(autouse=True)
def _rc_allowed_environment(monkeypatch):
    """#101: the entitlement read gate fails closed without
    RC_ALLOWED_ENVIRONMENT (same pin as ``test_entitlement``)."""
    monkeypatch.setenv("RC_ALLOWED_ENVIRONMENT", "PRODUCTION")


class _Clock:
    def __init__(self, value: datetime) -> None:
        self.value = value

    def __call__(self) -> datetime:
        return self.value


async def _plus_subject(db_sessionmaker, expires_at: datetime | None = None) -> None:
    """SUBJECT holds an active subscription (default: outlives the test month)."""
    await _seed_subscription(
        db_sessionmaker,
        "active",
        expires_at=expires_at or datetime(2026, 11, 15, tzinfo=UTC),
    )


def _tracker(db_sessionmaker, clock: _Clock | None = None, **kw) -> UsageTracker:
    return UsageTracker(db_sessionmaker, now=clock or _Clock(_MID_MONTH), **kw)


# --- the number is the product ------------------------------------------------


async def test_default_limits_are_30_free_and_1000_plus():
    """The founder-set plan sizes. Pinned so a stray default edit (or a
    forgotten env override) can't silently change what a subscriber gets."""
    assert FREE_MONTHLY_LIMIT == 30
    assert SUBSCRIBER_MONTHLY_LIMIT == 1000


# --- the cap -------------------------------------------------------------------


async def test_subscriber_allowed_up_to_1000_then_denied(db_sessionmaker):
    """Plus is capped, not unlimited: question #1000 is served, #1001 hits the
    wall. This is the whole point of the change (unlimited was unaffordable)."""
    await _plus_subject(db_sessionmaker)
    await _seed_daily(
        db_sessionmaker, SUBSCRIBER_MONTHLY_LIMIT - 1, usage_date=_MONTH_START
    )
    t = _tracker(db_sessionmaker)

    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == 1

    assert await t.record_question(SUBJECT) == SUBSCRIBER_MONTHLY_LIMIT

    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert not allowed and remaining == 0
    # A denied account's record call must not inflate the counter past the cap.
    assert await t.record_question(SUBJECT) == SUBSCRIBER_MONTHLY_LIMIT


async def test_subscriber_is_not_held_to_the_free_30(db_sessionmaker):
    """Guards the opposite regression: past the free 30 a subscriber keeps
    playing — the free limit applies only to non-entitled accounts."""
    await _plus_subject(db_sessionmaker)
    await _seed_daily(db_sessionmaker, FREE_MONTHLY_LIMIT, usage_date=_MONTH_START)
    t = _tracker(db_sessionmaker)

    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == SUBSCRIBER_MONTHLY_LIMIT - FREE_MONTHLY_LIMIT
    assert await t.record_question(SUBJECT) == FREE_MONTHLY_LIMIT + 1


async def test_subscriber_past_1000_spends_pack_credits(db_sessionmaker):
    """After the allowance a subscriber is treated like a free account at its
    wall: purchased pack credits are spent automatically, one per served
    question — the pack the paywall offers must actually work for them."""
    await _plus_subject(db_sessionmaker)
    await _seed_daily(
        db_sessionmaker, SUBSCRIBER_MONTHLY_LIMIT, usage_date=_MONTH_START
    )
    await _seed_credit(db_sessionmaker, 3)
    t = _tracker(db_sessionmaker)

    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == 3  # credit balance surfaced as remaining

    await t.record_question(SUBJECT)
    assert await _ledger_balance(db_sessionmaker) == 2
    assert await _consume_row_count(db_sessionmaker) == 1
    usage = await t.get_usage(SUBJECT)
    assert usage["questions_used"] == SUBSCRIBER_MONTHLY_LIMIT, (
        "a credit-funded question never touches the monthly counter"
    )


async def test_credits_untouched_while_plus_allowance_lasts(db_sessionmaker):
    """Credits are the fallback, not the first source: a subscriber under the
    cap must not burn purchased credits."""
    await _plus_subject(db_sessionmaker)
    await _seed_credit(db_sessionmaker, 5)
    t = _tracker(db_sessionmaker)

    await t.record_question(SUBJECT)

    assert await _ledger_balance(db_sessionmaker) == 5
    assert await _consume_row_count(db_sessionmaker) == 0


async def test_lapsed_subscription_applies_free_limit_to_same_counter(db_sessionmaker):
    """One monthly counter per account: when a subscription lapses mid-month the
    free 30 applies against what was already counted. A subscriber who used 500
    is over the free cap, so the wall comes up at once (intended: no second,
    fresh free allotment for lapsing)."""
    await _plus_subject(db_sessionmaker, expires_at=datetime(2026, 10, 20, tzinfo=UTC))
    await _seed_daily(db_sessionmaker, 500, usage_date=_MONTH_START)
    clock = _Clock(_MID_MONTH)
    t = _tracker(db_sessionmaker, clock)

    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == SUBSCRIBER_MONTHLY_LIMIT - 500

    clock.value = datetime(2026, 10, 25, tzinfo=UTC)  # same month, past expiry

    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert not allowed and remaining == 0
    assert await t.record_question(SUBJECT) == 500, "denied: counter is untouched"


# --- /usage numbers ---------------------------------------------------------------


async def test_get_usage_reports_real_limit_for_subscriber(db_sessionmaker):
    """The app shows "X of 1,000 left" for Plus: usage must return the real
    limit and remaining (it used to return None = unlimited), and ``plan``
    tells the 429 / analytics sites which account they are looking at."""
    await _plus_subject(db_sessionmaker)
    await _seed_daily(db_sessionmaker, 400, usage_date=_MONTH_START)

    usage = await _tracker(db_sessionmaker).get_usage(SUBJECT)

    assert usage["plan"] == "plus"
    assert usage["questions_used"] == 400
    assert usage["questions_limit"] == SUBSCRIBER_MONTHLY_LIMIT
    assert usage["remaining"] == SUBSCRIBER_MONTHLY_LIMIT - 400


async def test_get_usage_remaining_floors_at_zero_for_subscriber(db_sessionmaker):
    await _plus_subject(db_sessionmaker)
    await _seed_daily(
        db_sessionmaker, SUBSCRIBER_MONTHLY_LIMIT + 7, usage_date=_MONTH_START
    )

    usage = await _tracker(db_sessionmaker).get_usage(SUBJECT)

    assert usage["remaining"] == 0


async def test_get_usage_for_free_account_is_free_plan(db_sessionmaker):
    usage = await _tracker(db_sessionmaker).get_usage(SUBJECT)

    assert usage["plan"] == "free"
    assert usage["questions_limit"] == FREE_MONTHLY_LIMIT
    assert usage["remaining"] == FREE_MONTHLY_LIMIT


async def test_get_usage_legacy_premium_flag_alone_still_unlimited(db_sessionmaker):
    """Back-compat: the legacy ``is_premium`` column on a NON-entitled account
    keeps reporting unlimited (None) exactly as before; only real entitlement
    moved to a capped plan."""
    t = _tracker(db_sessionmaker)
    await t.set_premium(SUBJECT, True)

    usage = await t.get_usage(SUBJECT)

    assert usage["is_premium"] is True
    assert usage["plan"] == "free"
    assert usage["questions_limit"] is None and usage["remaining"] is None


# --- the 429 and its analytics ----------------------------------------------------


class _Url:
    path = "/api/v1/sessions/x/start"


class _Req:
    url = _Url()
    headers: ClassVar[dict] = {}


@pytest.fixture
def _no_rate_limit(monkeypatch):
    from app import rate_limit

    monkeypatch.setattr(rate_limit.limiter, "enabled", False)


async def _start_at_wall(tracker: UsageTracker) -> HTTPException:
    manager = SessionManager()
    session = await manager.create_session(user_id=SUBJECT)
    await manager.update_session(session)
    with pytest.raises(HTTPException) as exc_info:
        await start_quiz(
            request=_Req(),
            session_id=session.session_id,
            body=StartQuizRequest(),
            session_manager=manager,
            question_retriever=MagicMock(),
            usage_tracker=tracker,
            translation_service=None,
            tts_service=MagicMock(),
            audio=False,
            subject=AuthSubject(
                subject_id=SUBJECT, is_legacy=False, authenticated=True
            ),
        )
    return exc_info.value


async def test_429_for_subscriber_offers_no_upgrade(db_sessionmaker, _no_rate_limit):
    """A subscriber at the wall already has the only plan: the paywall must not
    offer a subscription to someone who holds one (``upgrade_available`` False),
    and the limit it reports is the Plus one. A free account at its wall keeps
    ``upgrade_available`` True (asserted in test_paywall_trigger_response)."""
    await _plus_subject(db_sessionmaker)
    t = _tracker(db_sessionmaker, subscriber_monthly_limit=2)
    await t.record_question(SUBJECT)
    await t.record_question(SUBJECT)

    exc = await _start_at_wall(t)

    assert exc.status_code == 429
    assert exc.detail["error"] == "quota_limit_reached"
    assert exc.detail["questions_limit"] == 2
    assert exc.detail["upgrade_available"] is False


def test_quota_hit_allowlist_keeps_plan():
    """The recorder silently drops any property not allowlisted. ``plan`` is the
    signal for deciding on a pricier tier, so losing it must fail a test."""
    cleaned = clean_properties(SERVER_EVENTS["quota_hit"], {"plan": "plus", "x": 1})
    assert cleaned == {"plan": "plus"}


class _Spy(AnalyticsRecorder):
    def __init__(self) -> None:
        super().__init__(None)
        self.hits: list[dict] = []

    def emit(self, name, *, subject_id=None, session_id=None, properties=None):
        if name == "quota_hit":
            self.hits.append(clean_properties(SERVER_EVENTS[name], properties or {}))


def _flow(tracker: UsageTracker, spy: _Spy) -> QuizFlowService:
    parser = MagicMock()
    parser.parse = AsyncMock(
        return_value=[{"intent_type": "answer", "extracted_data": {"answer": "Paris"}}]
    )
    current = Question(
        id="q_current",
        question="What is the capital of France?",
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="general",
        difficulty="medium",
    )
    retriever = MagicMock()
    retriever.get = AsyncMock(return_value=current)
    retriever.get_next_question = AsyncMock(return_value=current)
    flow = QuizFlowService(
        session_manager=AsyncMock(),
        input_parser=parser,
        question_retriever=retriever,
        answer_evaluator=MagicMock(),
        tts_service=None,
        usage_tracker=tracker,
        translation_service=None,
        analytics=spy,
    )
    flow.answer_evaluator.evaluate = AsyncMock(return_value=("correct", 1.0))
    return flow


async def test_mid_quiz_wall_for_subscriber_flags_plus_and_no_upgrade(db_sessionmaker):
    """The mid-quiz 429 (flow.py) follows the same rule as the start 429, and
    its ``quota_hit`` event carries ``plan`` so subscribers hitting the cap can
    be told apart from free users in the funnel."""
    await _plus_subject(db_sessionmaker)
    t = _tracker(db_sessionmaker, subscriber_monthly_limit=2)
    await t.record_question(SUBJECT)
    await t.record_question(SUBJECT)
    spy = _Spy()
    session = QuizSession(
        session_id="s_plus_wall",
        user_id=SUBJECT,
        phase=SessionPhase.ASKING,
        current_question_id="q_current",
        asked_question_ids=["q_current"],
        max_questions=10,
    )

    result = await _flow(t, spy).process_answer(session=session, answer_text="Paris")

    assert result.usage_limit_error["upgrade_available"] is False
    assert result.usage_limit_error["questions_limit"] == 2
    assert spy.hits == [
        {"stage": "mid_quiz", "questions_used": 2, "questions_limit": 2, "plan": "plus"}
    ]


async def test_mid_quiz_wall_for_free_account_flags_free_and_upgrade(db_sessionmaker):
    t = _tracker(db_sessionmaker, monthly_limit=2)
    await t.record_question(SUBJECT)
    await t.record_question(SUBJECT)
    spy = _Spy()
    session = QuizSession(
        session_id="s_free_wall",
        user_id=SUBJECT,
        phase=SessionPhase.ASKING,
        current_question_id="q_current",
        asked_question_ids=["q_current"],
        max_questions=10,
    )

    result = await _flow(t, spy).process_answer(session=session, answer_text="Paris")

    assert result.usage_limit_error["upgrade_available"] is True
    assert spy.hits[0]["plan"] == "free"
