"""Global daily ElevenLabs budget (#207 — production readiness, task 207.13).

ElevenLabs Starter is 30k credits a month and cannot be topped up; question
audio, answer read-backs and speech recognition all draw on it. The per-user
caps (``caps.py``) bound one account; this bounds the whole service: once
today's spend reaches ``ELEVENLABS_DAILY_CREDIT_BUDGET``, new speech goes to
the OpenAI voice and recogniser that already back ElevenLabs up, so one bad
day (many accounts, or a bug) cannot use up the month. Audio already cached
keeps playing in the ElevenLabs voice; tomorrow ElevenLabs is back.

Today's spend is measured, not estimated: ElevenLabs reports credits used in
the billing period (``character_count``), so today = now − the first reading
of the UTC day. That first reading is stored in ``usage_counters`` (first
writer wins), so a deploy or a second machine does not forget it.

Best effort and fail-open: if ElevenLabs or the database cannot be read, the
last known answer stands (at start: not exhausted). The reading is refreshed
at most once a minute, so it adds no call to almost every request.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from collections.abc import Awaitable, Callable
from datetime import UTC, date, datetime

import httpx
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..config import get_settings
from ..db.models import UsageCounter

logger = logging.getLogger(__name__)

SUBSCRIPTION_URL = "https://api.elevenlabs.io/v1/user/subscription"
REFRESH_S = 60.0
# Not a real subject id: the counter row that holds the day's first reading.
_SUBJECT = "__service__"
_METRIC = "elevenlabs_credits_at_day_start"


async def fetch_credits_used() -> int:
    """Credits used in the current billing period, per ElevenLabs."""
    async with httpx.AsyncClient(timeout=5.0) as client:
        resp = await client.get(
            SUBSCRIPTION_URL,
            headers={"xi-api-key": os.environ["ELEVENLABS_API_KEY"]},
        )
        resp.raise_for_status()
        return int(resp.json()["character_count"])


class ElevenLabsBudget:
    """Answers "has the service spent today's ElevenLabs budget?"."""

    def __init__(
        self,
        sessionmaker: async_sessionmaker[AsyncSession] | None,
        fetch: Callable[[], Awaitable[int]] = fetch_credits_used,
        now: Callable[[], datetime] | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._sessionmaker = sessionmaker
        self._fetch = fetch
        self._now = now or (lambda: datetime.now(UTC))
        self._clock = clock
        self._exhausted = False
        self.spent_today: int | None = None
        self._checked_at: float | None = None
        self._day: date | None = None  # UTC day of the last good reading
        self._lock = asyncio.Lock()
        self._background: asyncio.Task[None] | None = None

    async def exhausted(self) -> bool:
        budget = self._budget()
        if not budget:
            return False
        if not self._fresh():
            await self._refresh_once(budget)
        return self._exhausted

    def exhausted_now(self) -> bool:
        """The last verdict, without waiting (#240 audit). Speech calls this:
        a slow ElevenLabs meter or database must never delay question audio,
        so a stale reading is refreshed in the background and this request
        goes by the previous one (at start: not exhausted)."""
        budget = self._budget()
        if not budget:
            return False
        if not self._fresh() and (self._background is None or self._background.done()):
            self._background = asyncio.get_running_loop().create_task(
                self._refresh_once(budget)
            )
        return self._exhausted

    def _budget(self) -> int:
        budget = get_settings().elevenlabs_daily_credit_budget
        if not budget or self._sessionmaker is None:
            return 0
        if not os.environ.get("ELEVENLABS_API_KEY"):
            return 0
        return budget

    async def _refresh_once(self, budget: int) -> None:
        async with self._lock:
            if not self._fresh():  # another request may have just refreshed
                await self._refresh(budget)

    def status(self) -> tuple[date | None, bool, int | None]:
        """(UTC day of the last good reading, budget reached, credits spent
        that day) — for the #207 ops-watch mail; no network call."""
        return self._day, self._exhausted, self.spent_today

    def _fresh(self) -> bool:
        return (
            self._checked_at is not None
            and self._clock() - self._checked_at < REFRESH_S
        )

    async def _refresh(self, budget: int) -> None:
        self._checked_at = self._clock()
        today = self._now().date()
        try:
            used = await self._fetch()
            async with self._sessionmaker() as session:
                await session.execute(
                    pg_insert(UsageCounter)
                    .values(
                        subject_id=_SUBJECT,
                        usage_date=today,
                        metric=_METRIC,
                        amount=used,
                    )
                    .on_conflict_do_nothing()
                )
                start = (
                    await session.execute(
                        select(UsageCounter.amount).where(
                            UsageCounter.subject_id == _SUBJECT,
                            UsageCounter.usage_date == today,
                            UsageCounter.metric == _METRIC,
                        )
                    )
                ).scalar_one()
                await session.commit()
        except Exception as exc:  # noqa: BLE001 — fail open, keep the last answer
            logger.warning("ElevenLabs budget not refreshed: %s", type(exc).__name__)
            if self._day != today:
                self._exhausted = False  # yesterday's verdict does not carry over
            return
        self._day = today
        # The billing period can reset mid-day: then all of it is today's.
        spent = used - start if used >= start else used
        self.spent_today = spent  # #207: read by the ops watch for its mail
        exhausted = spent >= budget
        if exhausted != self._exhausted:
            logger.warning(
                "ElevenLabs daily budget %s: %d of %d credits spent today",
                "reached, using the OpenAI voice and recogniser"
                if exhausted
                else "clear again",
                spent,
                budget,
            )
        self._exhausted = exhausted


async def exclude_from_today(
    sessionmaker: async_sessionmaker[AsyncSession],
    credits: int,
    used_now: int,
    today: date | None = None,
) -> None:
    """Leave a deliberate batch's spend out of today's budget.

    Re-recording the question cache after a voice change spends many days of
    budget in an hour; counted, it would put every player on the OpenAI voice
    until midnight UTC. Moving the day's starting reading up by what the batch
    spent keeps the budget guarding player spend only, with no restart. No
    reading yet today: ``used_now`` (which already holds the batch) becomes it.
    """
    today = today or datetime.now(UTC).date()
    async with sessionmaker() as session:
        await session.execute(
            pg_insert(UsageCounter)
            .values(
                subject_id=_SUBJECT, usage_date=today, metric=_METRIC, amount=used_now
            )
            .on_conflict_do_update(
                index_elements=["subject_id", "usage_date", "metric"],
                set_={"amount": UsageCounter.amount + credits},
            )
        )
        await session.commit()
