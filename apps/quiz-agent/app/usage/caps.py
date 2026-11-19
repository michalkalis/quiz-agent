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
# charged as the longest answer iOS records (it hard-stops at 15 s)...
UNKNOWN_CLIP_SECONDS = 15
# ...or by its size, whichever is more. The header is the client's word, and
# OpenAI bills the audio that is really there (#240 audit): a compressed file is
# charged as if encoded at 32 kbit/s, the rate of the only compressed recorder
# iOS ships (AudioService, AAC 16 kHz), so an honest clip pays what it did and a
# 5 MB low-bitrate file pays ~22 min instead of 15 s.
COMPRESSED_BYTES_PER_SECOND = 4000
# A PCM WAV is charged from its sample format, never from the byte rate the
# header states, and never faster than 48 kHz stereo 16-bit.
MAX_PCM_BYTES_PER_SECOND = 48000 * 2 * 2
_PCM_FORMATS = (1, 3)  # integer PCM, IEEE float


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
    """Length of an uploaded answer in whole seconds, never less than the
    audio actually uploaded.

    Shipped builds upload 16-bit PCM WAV; the length is every byte from the
    ``data`` chunk on over the rate the ``fmt`` chunk's sample format implies
    (the stated byte rate is only believed when it is higher-charging).
    Anything else (legacy m4a, a compressed or broken WAV) is charged by size,
    at least ``UNKNOWN_CLIP_SECONDS``. Reads chunk headers only and leaves the
    file at offset 0.
    """
    try:
        total = audio_file.seek(0, 2)
        by_size = max(
            UNKNOWN_CLIP_SECONDS, math.ceil(total / COMPRESSED_BYTES_PER_SECOND)
        )
        audio_file.seek(0)
        if audio_file.read(12)[8:12] != b"WAVE":
            return by_size
        pos, byte_rate = 12, 0
        while pos + 8 <= total:
            audio_file.seek(pos)
            header = audio_file.read(24)
            chunk_id = header[:4]
            (size,) = struct.unpack("<I", header[4:8])
            # fmt body: format(2) channels(2) sample rate(4) byte rate(4)
            # block align(2) bits per sample(2)
            if chunk_id == b"fmt " and size >= 16 and len(header) == 24:
                fmt, channels, sample_rate, stated, _, bits = struct.unpack(
                    "<HHIIHH", header[8:24]
                )
                pcm_rate = sample_rate * channels * bits // 8
                if fmt in _PCM_FORMATS and pcm_rate > 0:
                    byte_rate = min(pcm_rate, stated or pcm_rate)
                    byte_rate = min(byte_rate, MAX_PCM_BYTES_PER_SECOND)
            elif chunk_id == b"data" and byte_rate > 0:
                # Every byte after the data header counts, whatever size the
                # chunk declares (a streamed WAV may say 0xFFFFFFFF).
                return max(1, math.ceil((total - pos - 8) / byte_rate))
            pos += 8 + size + (size & 1)
        return by_size
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

    @property
    def sessionmaker(self) -> async_sessionmaker[AsyncSession] | None:
        return self._sessionmaker

    def now(self) -> datetime:
        return self._now()

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
