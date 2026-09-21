"""#180 track C — quota × pack cross-cutting scenarios on injected time.

The free monthly quota is server logic (research 2026-09-14 §3), so its
rollover and its interplay with paid packs are pinned here in pytest with the
tracker's ONE injected time source (``UsageTracker(now=...)``) instead of the
wall clock:

* (b) a purchased pack keeps playing while the free quota is exhausted — the
  pack path never consults the free gate, and a free session on the same
  account is refused at the same moment (contrast, so the bypass can't widen).
* (c) the monthly reset is one UTC instant shared by the counter and the
  ``resets_at`` the client shows. Driven across both European DST transitions
  and the year wrap, at the last millisecond before the boundary (where the
  user's local calendar already says "next month") and at the boundary itself.

Scenario (a) — quota wall mid-quiz → purchase → the SAME quiz continues — is
a product change (today the wall finishes the session); it lands separately.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock, MagicMock

import pytest
from app.db.models import DailyUsage
from app.quiz.flow import QuizFlowService
from app.usage.tracker import UsageTracker
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession
from sqlalchemy import select

pytestmark = pytest.mark.asyncio

SUBJECT = "acct_quota_pack_scenarios"
PACK_ID = "e5b8c1a2-0000-4000-8000-000000000abc"
LIMIT = 3


class FakeNow:
    """The tracker's injected clock: ``value`` is whatever instant the test says."""

    def __init__(self, value: datetime) -> None:
        self.value = value

    def __call__(self) -> datetime:
        return self.value


def _question(qid: str) -> Question:
    return Question(
        id=qid,
        question="What is the capital of France?",
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="general",
        difficulty="medium",
    )


async def _exhaust_free_quota(tracker: UsageTracker) -> None:
    for _ in range(LIMIT):
        await tracker.record_question(SUBJECT)
    allowed, remaining, _ = await tracker.check_limit(SUBJECT)
    assert (allowed, remaining) == (False, 0), "precondition: free quota spent"


def _flow(tracker: UsageTracker, next_qid: str) -> QuizFlowService:
    input_parser = MagicMock()
    input_parser.parse = AsyncMock(
        return_value=[{"intent_type": "answer", "extracted_data": {"answer": "Paris"}}]
    )
    retriever = MagicMock()
    retriever.get = AsyncMock(return_value=_question("q_current"))
    retriever.get_next_question = AsyncMock(return_value=_question(next_qid))
    flow = QuizFlowService(
        session_manager=MagicMock(),
        input_parser=input_parser,
        question_retriever=retriever,
        answer_evaluator=MagicMock(),
        tts_service=None,
        usage_tracker=tracker,
        translation_service=None,
    )
    flow.answer_evaluator.evaluate = AsyncMock(return_value=("correct", 1.0))
    return flow


def _session(session_id: str, *, pack_id: str | None = None) -> QuizSession:
    session = QuizSession(
        session_id=session_id,
        user_id=SUBJECT,
        phase=SessionPhase.ASKING,
        current_question_id="q_current",
        asked_question_ids=["q_current"],
        max_questions=10,
    )
    session.pack_id = pack_id
    return session


# --- (b) pack play while the free quota is exhausted --------------------------


async def test_pack_keeps_playing_after_free_quota_is_exhausted(db_sessionmaker):
    """A paid pack must not stall behind the free wall — and the free path on
    the very same account must still be refused, so the bypass cannot silently
    widen into free questions for everyone."""
    now = FakeNow(datetime(2026, 10, 20, 12, 0, tzinfo=UTC))
    tracker = UsageTracker(db_sessionmaker, monthly_limit=LIMIT, now=now)
    await _exhaust_free_quota(tracker)

    pack = await _flow(tracker, "q_pack_next").process_answer(
        session=_session("s_pack", pack_id=PACK_ID), answer_text="Paris"
    )
    assert pack.usage_limit_error is None, "the pack path never asks the free gate"
    assert pack.next_question_dict is not None, "…so the next pack question is served"
    assert pack.next_question_dict["id"] == "q_pack_next"
    assert pack.quiz_finished is False

    free = await _flow(tracker, "q_free_next").process_answer(
        session=_session("s_free"), answer_text="Paris"
    )
    assert free.usage_limit_error is not None, "same account, free session: refused"
    assert free.usage_limit_error["error"] == "quota_limit_reached"
    assert free.next_question_dict is None
    assert free.usage_limit_error["evaluation"]["result"] == "correct", (
        "the wall must not swallow the grade of the answer that hit it"
    )

    usage = await tracker.get_usage(SUBJECT)
    assert usage["questions_used"] == LIMIT, (
        "pack play never counts against the free quota"
    )
    assert usage["credit_balance"] == 0, "…and never debits pack credits either"


# --- (c) monthly reset across DST and the year wrap ---------------------------

# (last instant of the month, the reset boundary, the boundary after that).
# The local Europe/Bratislava calendar already reads "next month" at each last
# instant: Nov 1 00:59 CET after DST ended (Oct 25), Apr 1 01:59 CEST after DST
# began (Mar 29), Jan 1 00:59 CET at the year wrap.
_BOUNDARIES = [
    pytest.param(
        datetime(2026, 10, 31, 23, 59, 59, 999_000, tzinfo=UTC),
        datetime(2026, 11, 1, tzinfo=UTC),
        datetime(2026, 12, 1, tzinfo=UTC),
        id="dst-end",
    ),
    pytest.param(
        datetime(2026, 3, 31, 23, 59, 59, 999_000, tzinfo=UTC),
        datetime(2026, 4, 1, tzinfo=UTC),
        datetime(2026, 5, 1, tzinfo=UTC),
        id="dst-start",
    ),
    pytest.param(
        datetime(2026, 12, 31, 23, 59, 59, 999_000, tzinfo=UTC),
        datetime(2027, 1, 1, tzinfo=UTC),
        datetime(2027, 2, 1, tzinfo=UTC),
        id="year-wrap",
    ),
]


@pytest.mark.parametrize(("last_instant", "boundary", "boundary_after"), _BOUNDARIES)
async def test_monthly_reset_is_one_utc_instant(
    db_sessionmaker, last_instant, boundary, boundary_after
):
    """The counter and the advertised ``resets_at`` agree on ONE UTC instant.
    A question at the last millisecond still belongs to the old month even
    though the user's local clock says the new one; at the boundary the free
    allowance is whole again and ``resets_at`` moves one month on."""
    now = FakeNow(last_instant)
    tracker = UsageTracker(db_sessionmaker, monthly_limit=LIMIT, now=now)
    await _exhaust_free_quota(tracker)

    allowed, remaining, resets_at = await tracker.check_limit(SUBJECT)
    assert (allowed, remaining, resets_at) == (False, 0, boundary)
    usage = await tracker.get_usage(SUBJECT)
    assert usage["questions_used"] == LIMIT
    assert usage["resets_at"] == boundary.isoformat(), (
        "the wire value is the exact UTC boundary the client counts down to"
    )
    async with db_sessionmaker() as s:
        rows = (await s.execute(select(DailyUsage.usage_date))).scalars().all()
    assert rows == [last_instant.date()], "counted on the UTC day, not the local one"

    now.value = boundary
    allowed, remaining, resets_at = await tracker.check_limit(SUBJECT)
    assert (allowed, remaining, resets_at) == (True, LIMIT, boundary_after)
    usage = await tracker.get_usage(SUBJECT)
    assert usage["questions_used"] == 0
    assert usage["remaining"] == LIMIT
    assert usage["resets_at"] == boundary_after.isoformat()

    await tracker.record_question(SUBJECT)
    usage = await tracker.get_usage(SUBJECT)
    assert usage["questions_used"] == 1, "the new month starts counting from zero"


async def test_gate_reads_time_once_per_call(db_sessionmaker):
    """One request straddling midnight on the 1st must not mix months: the
    month window, the entitlement expiry and ``resets_at`` all come from the
    single instant read at the top of the call. A clock that ticks past the
    boundary mid-call (the old per-helper ``datetime.now``) would count the
    October rows as spent while promising the DECEMBER reset."""
    last_instant = datetime(2026, 10, 31, 23, 59, 59, 999_000, tzinfo=UTC)
    boundary = datetime(2026, 11, 1, tzinfo=UTC)

    class TickingNow:
        def __init__(self) -> None:
            self.calls = 0

        def __call__(self) -> datetime:
            self.calls += 1
            return last_instant if self.calls == 1 else boundary

    setup = UsageTracker(
        db_sessionmaker, monthly_limit=LIMIT, now=FakeNow(last_instant)
    )
    await _exhaust_free_quota(setup)

    ticking = TickingNow()
    tracker = UsageTracker(db_sessionmaker, monthly_limit=LIMIT, now=ticking)
    allowed, remaining, resets_at = await tracker.check_limit(SUBJECT)

    assert ticking.calls == 1, "check_limit reads the clock exactly once"
    assert (allowed, remaining) == (False, 0), "…at the last instant the quota is spent"
    assert resets_at == boundary, (
        "…and the reset advertised is the one for THAT instant"
    )
    assert resets_at - last_instant < timedelta(seconds=1)
