"""Daily per-player cap on AI answer gradings (#218.7).

The LLM judge is the one paid call on every free-text answer the fast path
(exact match, MCQ, sound-alike, phonetic key) cannot settle. A looping client
or a stolen identity would spend shared credit on it without bound.

Past ``daily_cap_ai_gradings`` a player is NOT blocked (founder 2026-11-02, no
429, no service-wide cap): the evaluator skips the LLM and grades by the fast
path only, so a correct exact answer still counts. The first time anyone hits
the cap on a UTC day one e-mail goes out (the day's sentinel row is shared by
all machines); capped players and today's gradings show in ``ops-health``.

Fail-open like ``caps.py``: an unwritable counter never changes a verdict.
"""

from __future__ import annotations

import logging
from contextvars import ContextVar

from quiz_shared.ops_alerts import send_email_async
from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from ..config import get_settings
from ..db.models import UsageCounter
from .caps import DailyCapExceeded, UsageCaps

logger = logging.getLogger(__name__)

AI_GRADINGS = "ai_gradings"
_HIT_PREFIX = "ai_gradings_capped"  # one row per capped player, per day
_SERVICE = "__service__"
_MAIL_SENT = "ai_gradings_cap_mail"

# Set by the submit routes; None (evals, scripts, tests) = no cap.
_bound: ContextVar[tuple[UsageCaps, str] | None] = ContextVar(
    "ai_grading_cap", default=None
)


def bind_ai_grading(usage_caps: UsageCaps, subject_id: str | None) -> None:
    """Charge the AI gradings of this request to ``subject_id``."""
    _bound.set((usage_caps, subject_id) if subject_id else None)


async def ai_grading_allowed() -> bool:
    """Count one AI grading for the bound player; False once past the cap."""
    bound = _bound.get()
    if bound is None:
        return True
    caps, subject_id = bound
    try:
        await caps.consume(
            subject_id, AI_GRADINGS, 1, get_settings().daily_cap_ai_gradings
        )
    except DailyCapExceeded:
        await _record_hit(caps, subject_id)
        return False
    return True


async def _first_insert(session, subject_id: str, today, metric: str) -> bool:
    row = await session.execute(
        pg_insert(UsageCounter)
        .values(subject_id=subject_id, usage_date=today, metric=metric, amount=1)
        .on_conflict_do_nothing()
        .returning(UsageCounter.amount)
    )
    return row.first() is not None


async def _record_hit(caps: UsageCaps, subject_id: str) -> None:
    sessionmaker, today = caps.sessionmaker, caps.now().date()
    if sessionmaker is None:
        return
    try:
        async with sessionmaker() as session:
            await _first_insert(session, subject_id, today, _HIT_PREFIX)
            first_today = await _first_insert(session, _SERVICE, today, _MAIL_SENT)
            await session.commit()
    except Exception as exc:  # noqa: BLE001 — fail open
        logger.warning("AI cap hit not recorded: %s", type(exc).__name__)
        return
    if first_today:
        await send_email_async(
            "Trubbo: a player reached the daily AI grading cap",
            f"A player passed {get_settings().daily_cap_ai_gradings} AI answer "
            "gradings today (UTC). Their answers are now graded by the fast "
            "path only until midnight; nobody is blocked. One mail per day. "
            "Counts: GET /admin/ops-health.",
        )


async def ai_grading_stats(caps: UsageCaps) -> tuple[int, int]:
    """(players capped today, AI gradings today); (0, 0) without a database."""
    if caps.sessionmaker is None:
        return 0, 0
    today = caps.now().date()
    async with caps.sessionmaker() as session:
        capped = await session.scalar(
            select(func.count()).where(
                UsageCounter.usage_date == today,
                UsageCounter.metric == _HIT_PREFIX,
            )
        )
        total = await session.scalar(
            select(func.coalesce(func.sum(UsageCounter.amount), 0)).where(
                UsageCounter.usage_date == today, UsageCounter.metric == AI_GRADINGS
            )
        )
    return int(capped or 0), int(total or 0)
