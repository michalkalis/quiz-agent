"""The free voice-answer allowance (founder experiment, 2026-11-21).

A free player gets ``FREE_MONTHLY_LIMIT`` questions a month, of which at most
``FREE_MONTHLY_VOICE_LIMIT`` may be answered by voice: the transcription is the
only part of an answer with a real per-use cost. Typed and tapped answers
(``/sessions/{id}/input``) never touch this counter.

Counter: ``daily_usage.voice_answers``, summed over the calendar month exactly
like ``questions_count`` — the same reset instant and the same sign-in fold.
``/voice/submit`` charges it once a recording yields a usable transcript; a
recogniser error or "nothing heard" charges nothing. One answer, one charge:
the charge is keyed on (session, question) in ``usage_counters``, so a retried
upload of the same question (lost response, 503, "say it again") never charges
twice, and a re-submit of an already graded question is never charged.

Who it binds: an account with neither Trubbo Plus nor pack credits (both are
paying players), in a session that draws on the question quota (not a pack,
daily challenge or shared quiz). Everyone else is counted, never refused. A
family round (#236) is never refused mid-round, like the question quota.

Refusal: 429 ``{"code": "voice_limit_reached", ...}`` before any STT is paid
for. A build that declares the ``voice-allowance`` capability gets it as soon
as the allowance is spent. Shipped builds (up to TF 90) only when the
``voice_limit_old_builds`` switch is on: they show their generic "Too many
requests" screen, whose Try Again returns to the question where typing and
tapping still work. Not the quota body, which would end the round and open the
paywall with questions left. The switch is off by default because that screen
does not say why voice stopped.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import date, datetime
from typing import Any, Optional

from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from .. import app_switches
from ..client_capabilities import VOICE_ALLOWANCE, has_capability
from ..config import get_settings
from ..db.models import DailyUsage, UsageCounter
from .entitlement import account_credit_balance, account_is_entitled

OLD_BUILDS_SWITCH = "voice_limit_old_builds"


def answer_key(session_id: str, question_id: Optional[str]) -> str:
    """The ``usage_counters`` metric that marks ONE voice answer as charged."""
    return f"voice_answer:{session_id}:{question_id}"


async def voice_answers_since(
    session: AsyncSession, subject_id: str, month_start: date
) -> int:
    used = (
        await session.execute(
            select(func.coalesce(func.sum(DailyUsage.voice_answers), 0)).where(
                DailyUsage.subject_id == subject_id,
                DailyUsage.usage_date >= month_start,
            )
        )
    ).scalar_one()
    return int(used)


async def voice_is_limited(
    session: AsyncSession, subject_id: str, now: datetime
) -> bool:
    """True for a free player: no Trubbo Plus and no pack credits left."""
    if await account_is_entitled(session, subject_id, now=now):
        return False
    return await account_credit_balance(session, subject_id) <= 0


async def already_charged(session: AsyncSession, subject_id: str, key: str) -> bool:
    # Any day, not just today: a retry after midnight is still the same answer
    # (until the daily purge in ``caps.consume`` drops yesterday's rows).
    return (
        await session.execute(
            select(UsageCounter.metric)
            .where(UsageCounter.subject_id == subject_id, UsageCounter.metric == key)
            .limit(1)
        )
    ).first() is not None


async def charge(session: AsyncSession, subject_id: str, key: str, today: date) -> bool:
    """Mark ``key`` charged and add one voice answer to today's row — no commit.
    False (nothing written) when this answer was charged before."""
    if await already_charged(session, subject_id, key):
        return False
    marked = (
        await session.execute(
            pg_insert(UsageCounter)
            .values(subject_id=subject_id, usage_date=today, metric=key, amount=1)
            .on_conflict_do_nothing()
            .returning(UsageCounter.metric)
        )
    ).first()
    if marked is None:
        return False
    await session.execute(
        pg_insert(DailyUsage)
        .values(subject_id=subject_id, usage_date=today, voice_answers=1)
        .on_conflict_do_update(
            index_elements=["subject_id", "usage_date"],
            set_={"voice_answers": DailyUsage.voice_answers + 1},
        )
    )
    return True


def limit_error(used: int, limit: int, resets_at: datetime) -> HTTPException:
    # No `error` / `questions_used` / `upgrade_available`: a shipped build must
    # not decode this as the quota 429 (that one ends the round and opens the
    # paywall although questions are left). It lands on "Too many requests".
    return HTTPException(
        status_code=429,
        detail={
            "code": "voice_limit_reached",
            "message": (
                "You've used this month's free voice answers. "
                "Type or tap your answer instead."
            ),
            "voice_answers_used": used,
            "voice_answers_limit": limit,
            "resets_at": resets_at.isoformat(),
        },
    )


async def gate_voice_answer(
    quiz_flow: Any,
    session: Any,
    question_id: Optional[str],
    is_resubmission: bool,
    switch_sessionmaker: Any,
    on_refused: Callable[[], None],
) -> Optional[str]:
    """Before transcription: refuse a voice answer past the allowance, or
    return the key to charge once the transcript is usable (None = nothing
    to charge: a re-submit, or a session the question quota does not bind)."""
    tracker = quiz_flow.usage_tracker
    if (
        is_resubmission
        or tracker is None
        or not session.user_id
        or session.is_quota_exempt
    ):
        return None
    key = answer_key(session.session_id, question_id)
    check = await tracker.check_voice_answer(session.user_id, key)
    if check.allowed:
        return key
    enforced = not session.age_band and (
        has_capability(session, VOICE_ALLOWANCE)
        or await app_switches.is_on(
            get_settings(), switch_sessionmaker, OLD_BUILDS_SWITCH
        )
    )
    quiz_flow.analytics.emit(
        "voice_quota_hit",
        subject_id=session.user_id,
        session_id=session.session_id,
        properties={
            "voice_answers_used": check.used,
            "voice_answers_limit": check.limit,
            "enforced": enforced,
        },
    )
    if not enforced:
        return key
    on_refused()
    raise limit_error(check.used, check.limit, check.resets_at)
