"""Entitlement/quota gate tests for issue #93 (subscription IAP + packs).

Pins the Design §3 serving order **subscription → free-30 → pack credits → deny**
enforced by ``UsageTracker.check_limit`` (non-mutating) and the single consume
point ``record_question`` (mutating). The load-bearing invariants:

* the free cap is **30** (down from 100);
* an ``active`` OR ``grace`` subscription (``expires_at > now``) is unlimited and
  is neither counted nor debited;
* one served question on the credit path = exactly one ``-1`` debit, and a
  fully-spent balance debits nothing (no double-spend / #90 TOCTOU);
* a **pre-record 500** (question retrieval fails between ``check_limit`` and
  ``record_question``) debits nothing — driven at the flow layer;
* the entitlement read **default-denies** a null/absent account (#89).

DB-backed: the fixtures target ``TEST_DATABASE_URL`` (see ``conftest.py``); the
suite skips wholesale when it is unset.
"""

from __future__ import annotations

import asyncio
from datetime import timedelta
from unittest.mock import AsyncMock, MagicMock

import pytest
from sqlalchemy import func, select

from app.db.base import utcnow
from app.db.models import CreditLedger, DailyUsage, Product, Subscription
from app.quiz.flow import QuizFlowService
from app.usage.entitlement import (
    EntitlementService,
    account_credit_balance,
    account_is_entitled,
)
from app.usage.tracker import FREE_MONTHLY_LIMIT, UsageTracker, _month_start
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

pytestmark = pytest.mark.asyncio

SUBJECT = "acct_entitlement_subject"
_PRODUCT_ID = "com.carquiz.unlimited.monthly"


# --- seeding helpers ---------------------------------------------------------


async def _seed_daily(db_sessionmaker, count: int, *, usage_date=None) -> None:
    async with db_sessionmaker() as s:
        s.add(
            DailyUsage(
                subject_id=SUBJECT,
                usage_date=usage_date or _month_start(),
                questions_count=count,
            )
        )
        await s.commit()


async def _seed_subscription(db_sessionmaker, status: str, *, expires_at) -> None:
    async with db_sessionmaker() as s:
        s.add(Product(product_id=_PRODUCT_ID, kind="subscription", tier="unlimited"))
        s.add(
            Subscription(
                account_id=SUBJECT,
                product_id=_PRODUCT_ID,
                status=status,
                expires_at=expires_at,
                rc_original_txn_id="txn_orig_1",
                last_event_ts_ms=1,
            )
        )
        await s.commit()


async def _seed_credit(db_sessionmaker, delta: int, *, kind="grant") -> None:
    async with db_sessionmaker() as s:
        s.add(
            CreditLedger(
                account_id=SUBJECT,
                delta=delta,
                kind=kind,
                reason="pack",
                store_txn_id=f"pack_txn_{delta}_{kind}",
            )
        )
        await s.commit()


async def _ledger_balance(db_sessionmaker, account_id=SUBJECT) -> int:
    async with db_sessionmaker() as s:
        return int(
            (
                await s.execute(
                    select(func.coalesce(func.sum(CreditLedger.delta), 0)).where(
                        CreditLedger.account_id == account_id
                    )
                )
            ).scalar_one()
        )


async def _consume_row_count(db_sessionmaker) -> int:
    async with db_sessionmaker() as s:
        return int(
            (
                await s.execute(
                    select(func.count())
                    .select_from(CreditLedger)
                    .where(
                        CreditLedger.account_id == SUBJECT,
                        CreditLedger.kind == "consume",
                    )
                )
            ).scalar_one()
        )


def _tracker(db_sessionmaker, limit=FREE_MONTHLY_LIMIT) -> UsageTracker:
    return UsageTracker(db_sessionmaker, monthly_limit=limit)


# --- free-tier sizing --------------------------------------------------------


async def test_free_cap_is_30(db_sessionmaker):
    """The free monthly cap is 30 (issue #93, down from 100): allowed at 29
    used, denied once 30 are used."""
    assert FREE_MONTHLY_LIMIT == 30

    t = _tracker(db_sessionmaker)
    await _seed_daily(db_sessionmaker, 29)

    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == 1

    # The 30th question records, then the gate closes.
    assert await t.record_question(SUBJECT) == 30
    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert not allowed and remaining == 0


# --- subscription entitlement ------------------------------------------------


async def test_active_sub_unlimited(db_sessionmaker):
    """An active sub (expires in the future) is unlimited: check returns -1 and
    record neither increments the free counter nor debits credits."""
    await _seed_subscription(
        db_sessionmaker, "active", expires_at=utcnow() + timedelta(days=30)
    )
    await _seed_credit(db_sessionmaker, 5)  # present but must not be touched
    t = _tracker(db_sessionmaker)

    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == -1

    # Recording is a no-op for the quota: counter stays 0, balance stays 5.
    assert await t.record_question(SUBJECT) == 0
    assert await t.record_question(SUBJECT) == 0
    usage = await t.get_usage(SUBJECT)
    assert usage["questions_used"] == 0
    assert usage["questions_limit"] is None
    assert usage["subscription_status"] == "active"
    assert usage["credit_balance"] == 5
    assert await _ledger_balance(db_sessionmaker) == 5


async def test_grace_sub_unlimited(db_sessionmaker):
    """A grace sub (Apple billing-retry window, expires_at in the future) still
    counts as entitled — it must not fall through to the free allotment."""
    await _seed_subscription(
        db_sessionmaker, "grace", expires_at=utcnow() + timedelta(days=3)
    )
    # Free allotment already exhausted: only entitlement can allow here.
    await _seed_daily(db_sessionmaker, FREE_MONTHLY_LIMIT)
    t = _tracker(db_sessionmaker)

    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == -1


async def test_expired_sub_not_entitled(db_sessionmaker):
    """A row whose expires_at is in the past is NOT entitled — it falls through
    to the free allotment (guards the ``expires_at > now`` half of the rule)."""
    await _seed_subscription(
        db_sessionmaker, "active", expires_at=utcnow() - timedelta(days=1)
    )
    async with db_sessionmaker() as s:
        assert await account_is_entitled(s, SUBJECT) is False


# --- pack credits ------------------------------------------------------------


async def test_credit_debit_once_per_served(db_sessionmaker):
    """Free exhausted + credits present → check allows via credits, and one
    served question debits exactly one credit (one consume row)."""
    await _seed_daily(db_sessionmaker, FREE_MONTHLY_LIMIT)
    await _seed_credit(db_sessionmaker, 5)
    t = _tracker(db_sessionmaker)

    allowed, remaining, _ = await t.check_limit(SUBJECT)
    assert allowed and remaining == 5  # credit balance surfaced as remaining

    await t.record_question(SUBJECT)
    assert await _ledger_balance(db_sessionmaker) == 4
    assert await _consume_row_count(db_sessionmaker) == 1


async def test_no_double_spend_sequential(db_sessionmaker):
    """The guarded debit can't take a spent balance negative: with one credit,
    two *sequential* record calls debit only once (#90 TOCTOU — record
    re-derives the path independently of check)."""
    await _seed_daily(db_sessionmaker, FREE_MONTHLY_LIMIT)
    await _seed_credit(db_sessionmaker, 1)
    t = _tracker(db_sessionmaker)

    await t.record_question(SUBJECT)  # balance 1 -> 0
    await t.record_question(SUBJECT)  # guard fails, no row inserted

    assert await _ledger_balance(db_sessionmaker) == 0
    assert await _consume_row_count(db_sessionmaker) == 1

    allowed, _, _ = await t.check_limit(SUBJECT)
    assert not allowed


async def test_no_double_spend_concurrent(db_sessionmaker):
    """The last credit can't be double-spent under CONCURRENT debits (#90
    TOCTOU) — the invariant the sequential test above CANNOT catch (it passes
    even against the un-serialized guard, hence false confidence).

    Drives two transactions to the guarded debit at balance=1 with a
    deterministic interleave, exercising the tracker's real
    ``_debit_one_credit`` (advisory lock + guarded insert) on two separate
    connections:

    1. Txn A debits (acquires the per-account advisory lock, inserts -1) but
       does NOT commit — the lock is held to A's commit.
    2. Txn B starts the same debit as a task. WITHOUT the lock it would take a
       fresh READ COMMITTED snapshot, not see A's uncommitted -1, read balance
       1, and insert a second -1 → balance -1, two consume rows (the bug).
       WITH the lock it blocks on the advisory lock instead.
    3. A commits, releasing the lock. B unblocks, its guard now re-reads the
       committed balance 0 and inserts nothing.

    Result under the fix: exactly one consume row, balance floored at 0. This
    FAILS against the un-serialized guard and PASSES against the fix. Needs a
    pool of ≥2 connections (the test engine's default is 5)."""
    await _seed_daily(db_sessionmaker, FREE_MONTHLY_LIMIT)
    await _seed_credit(db_sessionmaker, 1)
    t = _tracker(db_sessionmaker)

    async with db_sessionmaker() as sa, db_sessionmaker() as sb:
        # (1) A debits, holding its transaction (and the advisory lock) open.
        await t._debit_one_credit(sa, SUBJECT)

        # (2) B races the same debit. Under the fix it blocks on the advisory
        #     lock; without it, B completes the double-spend during the wait.
        async def _b_debit() -> None:
            await t._debit_one_credit(sb, SUBJECT)
            await sb.commit()

        task_b = asyncio.create_task(_b_debit())
        # Give B time to either block on the lock (fix) or double-spend (bug).
        await asyncio.sleep(0.3)

        # (3) A commits, releasing the lock so B can re-evaluate its guard.
        await sa.commit()
        await task_b

    assert await _ledger_balance(db_sessionmaker) == 0
    assert await _consume_row_count(db_sessionmaker) == 1

    allowed, _, _ = await t.check_limit(SUBJECT)
    assert not allowed


# --- default-deny (#89) ------------------------------------------------------


async def test_null_account_denied(db_sessionmaker):
    """The entitlement read default-denies a null/absent account (preserves the
    #89 null-subject bypass fix): no subscription, zero balance — never a
    bypass, even if other accounts hold credits."""
    await _seed_credit(db_sessionmaker, 100)  # belongs to SUBJECT, not to None
    svc = EntitlementService(db_sessionmaker)

    assert await svc.is_entitled(None) is False
    assert await svc.is_entitled("") is False
    assert await svc.credit_balance(None) == 0
    assert await svc.credit_balance("") == 0

    async with db_sessionmaker() as s:
        assert await account_is_entitled(s, None) is False
        assert await account_credit_balance(s, None) == 0


# --- pre-record 500 (integration through the flow) ---------------------------


def _make_question(qid="q_current") -> Question:
    return Question(
        id=qid,
        question="What is the capital of France?",
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="general",
        difficulty="medium",
    )


async def test_pre_record_retrieval_500_no_debit(db_sessionmaker):
    """A 500 in question retrieval that fires AFTER ``check_limit`` but BEFORE
    ``record_question`` must debit nothing — the check→record split means the
    credit is only consumed once the next question is secured (Design §3).

    Driven at the flow layer: the account is on the credit path (free exhausted,
    balance 5); ``get_next_question`` raises between the gate and the consume
    point; the ledger balance must be unchanged."""
    await _seed_daily(db_sessionmaker, FREE_MONTHLY_LIMIT)
    await _seed_credit(db_sessionmaker, 5)
    tracker = _tracker(db_sessionmaker)

    # Sanity: the gate would allow via credits before retrieval blows up.
    allowed, _, _ = await tracker.check_limit(SUBJECT)
    assert allowed

    input_parser = MagicMock()
    input_parser.parse = AsyncMock(
        return_value=[{"intent_type": "answer", "extracted_data": {"answer": "Paris"}}]
    )
    question_retriever = MagicMock()
    question_retriever.get = MagicMock(return_value=_make_question())
    question_retriever.get_next_question = MagicMock(
        side_effect=RuntimeError("retrieval 500 before record")
    )

    flow = QuizFlowService(
        session_manager=MagicMock(),
        input_parser=input_parser,
        question_retriever=question_retriever,
        answer_evaluator=MagicMock(),
        tts_service=None,
        usage_tracker=tracker,
        translation_service=None,
    )
    flow.answer_evaluator.evaluate = AsyncMock(return_value=("correct", 1.0))

    session = QuizSession(
        session_id="s_500",
        user_id=SUBJECT,
        phase=SessionPhase.ASKING,
        current_question_id="q_current",
        asked_question_ids=["q_current"],
        max_questions=10,
    )

    with pytest.raises(RuntimeError):
        await flow.process_answer(session=session, answer_text="Paris")

    # The debit lives in record_question, which was never reached.
    assert await _ledger_balance(db_sessionmaker) == 5
    assert await _consume_row_count(db_sessionmaker) == 0
