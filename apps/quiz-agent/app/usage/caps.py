"""Per-user daily cost caps (#207 — production readiness, task 207.13).

The question quota (``tracker.py``) bounds what a player is *served*, not what
the server pays for around it: a recording that yields no answer, a re-submit
of an already-graded question, a realtime STT token or an entitlement sync are
all free to the caller and billed to us. Without a ceiling one account — or one
leaked attested identity — could loop any of them and drain a provider balance
that every other player shares (ElevenLabs Starter is 30k credits a month).

Each cap counts one metric per subject per UTC day in ``usage_counters`` and is
sized so a heavy real player never meets it (values and reasoning in
``config.Settings.daily_cap_*``). Over a cap the request is refused *before*
the paid call with a plain 429 (``DailyCapExceeded.http_error``). Shipped iOS
builds already handle that shape: it does not decode as the quota body, so it
never opens the paywall; a refused realtime token drops to batch recording, a
refused entitlement sync is best effort, a refused answer shows "Too many
requests, try again in a moment".

Fail-open on purpose: the caps guard against abuse, so a counter that cannot
be written (DB blip) must not take a real player's answer down with it.
"""

from __future__ import annotations

import logging
import math
import struct
from collections.abc import Callable
from datetime import date, datetime, timedelta, timezone
from typing import BinaryIO

from fastapi import HTTPException
from sqlalchemy import delete
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..db.models import UsageCounter

logger = logging.getLogger(__name__)

STT_TOKENS = "stt_tokens"
STT_SECONDS = "stt_seconds"
ENTITLEMENT_SYNCS = "entitlement_syncs"
_ANSWER_ATTEMPTS = "answer_attempts"

# A recording whose length cannot be read (not a WAV: legacy m4a builds) is
# charged as the longest answer iOS records (it hard-stops at 15 s).
UNKNOWN_CLIP_SECONDS = 15


def answer_attempts(question_id: str) -> str:
    """Metric for submits of ONE question (re-submits are free to the caller)."""
    return f"{_ANSWER_ATTEMPTS}:{question_id}"


def _next_midnight(now: datetime) -> datetime:
    return datetime.combine(
        now.date() + timedelta(days=1), datetime.min.time(), tzinfo=timezone.utc
    )


class DailyCapExceeded(Exception):
    """A subject reached a daily cap; nothing was paid for this request."""

    def __init__(self, metric: str, limit: int, now: datetime) -> None:
        super().__init__(f"daily cap reached: {metric}")
        # The family name only: a per-question metric carries a question id.
        self.cap = metric.split(":", 1)[0]
        self.limit = limit
        self.resets_at = _next_midnight(now)
        self._now = now

    def http_error(self) -> HTTPException:
        # No `questions_used` / `upgrade_available`: iOS must NOT read this as
        # the quota 429 (that one opens the paywall, and paying does not lift
        # an abuse cap). It lands on the generic "Too many requests" instead.
        return HTTPException(
            status_code=429,
            detail={
                "code": "daily_cap",
                "cap": self.cap,
                "message": "Daily limit reached. Please try again tomorrow.",
                "resets_at": self.resets_at.isoformat(),
            },
            headers={
                "Retry-After": str(
                    max(1, int((self.resets_at - self._now).total_seconds()))
                )
            },
        )


def recording_seconds(audio_file: BinaryIO) -> int:
    """Length of an uploaded answer in whole seconds, from its WAV header.

    Shipped builds upload 16-bit PCM WAV; the length is the ``data`` chunk over
    the ``fmt`` chunk's byte rate. Anything unreadable (legacy m4a, a broken
    header) is charged ``UNKNOWN_CLIP_SECONDS``. Reads chunk headers only and
    leaves the file at offset 0.
    """
    try:
        total = audio_file.seek(0, 2)
        audio_file.seek(0)
        if audio_file.read(12)[8:12] != b"WAVE":
            return UNKNOWN_CLIP_SECONDS
        pos, byte_rate = 12, 0
        while pos + 8 <= total:
            audio_file.seek(pos)
            header = audio_file.read(20)
            chunk_id = header[:4]
            (size,) = struct.unpack("<I", header[4:8])
            # fmt body: format(2) channels(2) sample rate(4) byte rate(4)
            if chunk_id == b"fmt " and size >= 12 and len(header) == 20:
                (byte_rate,) = struct.unpack("<I", header[16:20])
            elif chunk_id == b"data" and byte_rate > 0:
                # A streamed WAV may declare 0xFFFFFFFF; trust the bytes present.
                present = min(size, total - pos - 8)
                return max(1, math.ceil(present / byte_rate))
            pos += 8 + size + (size & 1)
        return UNKNOWN_CLIP_SECONDS
    finally:
        audio_file.seek(0)


class UsageCaps:
    """Daily per-subject counters with a ceiling. ``sessionmaker=None`` (no
    database configured) disables every cap."""

    def __init__(
        self,
        sessionmaker: async_sessionmaker[AsyncSession] | None,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self._sessionmaker = sessionmaker
        self._now = now or (lambda: datetime.now(timezone.utc))
        self._purged_before: date | None = None

    async def consume(
        self, subject_id: str | None, metric: str, amount: int, limit: int
    ) -> None:
        """Count ``amount`` of ``metric`` for today; raise ``DailyCapExceeded``
        when the subject had already reached ``limit`` before this request.

        The request that crosses the line still passes (a long last recording
        is not cut off mid-day); every later one is refused. ``limit`` 0, no
        subject or no database = no cap.
        """
        if not limit or not subject_id or amount <= 0 or self._sessionmaker is None:
            return
        now = self._now()
        today = now.date()
        try:
            async with self._sessionmaker() as session:
                if self._purged_before != today:
                    # Only today's rows matter; drop the rest once a day.
                    await session.execute(
                        delete(UsageCounter).where(UsageCounter.usage_date < today)
                    )
                    self._purged_before = today
                total = (
                    await session.execute(
                        pg_insert(UsageCounter)
                        .values(
                            subject_id=subject_id,
                            usage_date=today,
                            metric=metric,
                            amount=amount,
                        )
                        .on_conflict_do_update(
                            index_elements=["subject_id", "usage_date", "metric"],
                            set_={"amount": UsageCounter.amount + amount},
                        )
                        .returning(UsageCounter.amount)
                    )
                ).scalar_one()
                await session.commit()
        except Exception as exc:  # noqa: BLE001 — fail open, see module docstring
            logger.warning(
                "Usage cap %s not counted (fail open): %s", metric, type(exc).__name__
            )
            return
        if total - amount >= limit:
            logger.warning(
                "Daily cap reached: subject=%s cap=%s limit=%d",
                subject_id,
                metric.split(":", 1)[0],
                limit,
            )
            raise DailyCapExceeded(metric, limit, now)
