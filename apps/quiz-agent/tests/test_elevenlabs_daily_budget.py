"""Service-wide ElevenLabs daily budget (#207 — production readiness, 207.13).

Why: ElevenLabs Starter is 30k credits a month and cannot be topped up. Per-user
caps bound one account, not many accounts (or a bug) on one bad day. Past the
day's budget new speech must switch to the OpenAI voice that already
backs ElevenLabs up — degrade, never go silent — and switch back the
next UTC day. Spend is ElevenLabs' own meter, so the day's first reading must
survive a deploy, and a meter that cannot be read must never block play.
"""

from __future__ import annotations

import asyncio
import os
from datetime import UTC, datetime, timedelta

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

import pytest
from app.tts.service import TTSService
from app.usage.elevenlabs_budget import ElevenLabsBudget

from tests.test_tts_synthesize_budget import FakeProvider

pytestmark = pytest.mark.asyncio

BUDGET = 1000
_T0 = datetime(2026, 10, 16, 9, 0, tzinfo=UTC)


@pytest.fixture(autouse=True)
def _env(monkeypatch, tmp_path):
    monkeypatch.setenv("ELEVENLABS_API_KEY", "k")
    monkeypatch.setenv("ELEVENLABS_DAILY_CREDIT_BUDGET", str(BUDGET))
    monkeypatch.setenv("TTS_CACHE_DIR", str(tmp_path / "cache"))


class Meter:
    """ElevenLabs' credits-used-this-period, and how often it was read."""

    def __init__(self, used: int):
        self.used, self.reads, self.down = used, 0, False

    async def __call__(self) -> int:
        self.reads += 1
        if self.down:
            raise ConnectionError("elevenlabs down")
        return self.used


def _budget(db, meter, now, clock):
    return ElevenLabsBudget(db, fetch=meter, now=lambda: now[0], clock=lambda: clock[0])


async def test_today_is_measured_from_the_first_reading_of_the_day(db_sessionmaker):
    meter, now, clock = Meter(12_000), [_T0], [0.0]
    budget = _budget(db_sessionmaker, meter, now, clock)
    assert not await budget.exhausted()  # 12k spent earlier in the month: not today

    meter.used += BUDGET
    clock[0] += 61
    assert await budget.exhausted()

    now[0] += timedelta(days=1)  # next UTC day: ElevenLabs is back
    clock[0] += 61
    assert not await budget.exhausted()


async def test_a_deploy_does_not_forget_the_day_start(db_sessionmaker):
    """A fresh process must not take its own first reading as the day start,
    or every deploy would hand out a fresh daily budget."""
    meter, now, clock = Meter(5_000), [_T0], [0.0]
    await _budget(db_sessionmaker, meter, now, clock).exhausted()

    meter.used += BUDGET
    restarted = _budget(db_sessionmaker, meter, now, clock)
    assert await restarted.exhausted()


async def test_a_billing_reset_mid_day_counts_from_zero(db_sessionmaker):
    meter, now, clock = Meter(29_000), [_T0], [0.0]
    budget = _budget(db_sessionmaker, meter, now, clock)
    await budget.exhausted()
    meter.used, clock[0] = BUDGET + 10, 61.0  # period reset, then spend
    assert await budget.exhausted()


async def test_reads_the_meter_at_most_once_a_minute(db_sessionmaker):
    """It sits in front of every question audio and every recording."""
    meter, now, clock = Meter(0), [_T0], [0.0]
    budget = _budget(db_sessionmaker, meter, now, clock)
    for _ in range(20):
        await budget.exhausted()
    assert meter.reads == 1


async def test_an_unreadable_meter_never_blocks_play(db_sessionmaker):
    meter, now, clock = Meter(0), [_T0], [0.0]
    meter.down = True
    assert not await _budget(db_sessionmaker, meter, now, clock).exhausted()

    meter.down = False
    budget = _budget(db_sessionmaker, meter, now, clock)
    await budget.exhausted()
    meter.used, clock[0] = BUDGET, 61.0
    assert await budget.exhausted()
    meter.down = True
    now[0], clock[0] = now[0] + timedelta(days=1), 122.0
    assert not await budget.exhausted()  # yesterday's verdict does not carry over


async def test_zero_budget_or_no_database_means_no_budget(monkeypatch):
    assert not await ElevenLabsBudget(None, fetch=Meter(10**9)).exhausted()
    monkeypatch.setenv("ELEVENLABS_DAILY_CREDIT_BUDGET", "0")
    assert not await ElevenLabsBudget(object(), fetch=Meter(10**9)).exhausted()


# ── What switches over ───────────────────────────────────────────────────────


class Spent:
    def __init__(self, value: bool = True):
        self.value = value

    async def exhausted(self) -> bool:
        return self.value

    def exhausted_now(self) -> bool:
        return self.value


class HeldMeter(Meter):
    """ElevenLabs' meter answering only when the test lets it (a slow API)."""

    def __init__(self, used: int):
        super().__init__(used)
        self.release = asyncio.Event()

    async def __call__(self) -> int:
        self.reads += 1
        await self.release.wait()
        return self.used


async def test_a_slow_meter_never_delays_question_audio(db_sessionmaker):
    """#240 audit: the budget reading refreshes once a minute and calls the
    ElevenLabs API (5 s timeout) plus the database. Done inline, the first
    question of each minute waited for it, cached audio too, outside the 6 s
    primary cut-off: during an ElevenLabs slowdown that pushed a question past
    the app's 10 s wait. Speech must go by the last verdict and refresh in the
    background."""
    meter, now, clock = HeldMeter(5_000), [_T0], [0.0]
    budget = _budget(db_sessionmaker, meter, now, clock)
    primary, fallback = (
        FakeProvider("elevenlabs", "v-el"),
        FakeProvider("openai", "nova"),
    )
    tts = TTSService(provider=primary, fallback_provider=fallback)
    tts.primary_budget = budget

    # The meter is held: a synthesis that waited for it would never return.
    # (The timeout is only a guard so a regression fails instead of hanging.)
    first = await asyncio.wait_for(tts.synthesize("A question"), 5)
    cached = await asyncio.wait_for(tts.synthesize("A question"), 5)
    assert first == cached == b"elevenlabs-audio"
    assert meter.reads == 1  # one background refresh, not one per request

    # The refresh lands later and its verdict applies from then on.
    meter.release.set()
    await budget._background
    meter.used += BUDGET
    clock[0] += 61  # stale again: the next request starts a refresh...
    next_audio = await asyncio.wait_for(tts.synthesize("Next question"), 5)
    assert next_audio == b"elevenlabs-audio"  # ...and goes by the last verdict
    await budget._background
    assert await asyncio.wait_for(tts.synthesize("Third question"), 5) == (
        b"openai-audio"
    )


async def test_spent_budget_moves_new_speech_to_the_fallback_voice():
    primary, fallback = (
        FakeProvider("elevenlabs", "v-el"),
        FakeProvider("openai", "nova"),
    )
    tts = TTSService(provider=primary, fallback_provider=fallback)
    tts.primary_budget = Spent(False)
    await tts.synthesize("Already paid for")

    tts.primary_budget = Spent(True)
    assert await tts.synthesize("Already paid for") == b"elevenlabs-audio"  # cache
    assert await tts.synthesize("A new question") == b"openai-audio"
    assert primary.calls == ["Already paid for"]


async def test_without_a_fallback_voice_the_question_still_speaks():
    primary = FakeProvider("elevenlabs", "v-el")
    tts = TTSService(provider=primary, fallback_provider=FakeProvider("openai", "n"))
    tts.fallback = None
    tts.primary_budget = Spent(True)
    assert await tts.synthesize("Hello") == b"elevenlabs-audio"


async def test_spent_budget_refuses_realtime_tokens(monkeypatch):
    """Same 503 as an empty quota: iOS then records in batch mode, where the
    OpenAI recogniser takes over (above)."""
    from app.api import deps
    from app.api.routes import misc as misc_routes
    from app.auth.identity import AuthSubject
    from app.rate_limit import limiter
    from fastapi import FastAPI
    from httpx import ASGITransport, AsyncClient

    from tests.test_misc_elevenlabs_quota_gate import _mock_elevenlabs

    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.state.elevenlabs_budget = Spent(True)
    app.include_router(misc_routes.router, prefix="/api/v1")
    app.dependency_overrides[deps.require_auth_or_grace] = lambda: AuthSubject(
        subject_id="u1", is_legacy=False, authenticated=True
    )
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        _mock_elevenlabs(monkeypatch, remaining=20_000)
        resp = await c.post("/api/v1/elevenlabs/token")
    assert resp.status_code == 503
    assert "token" not in resp.json()


async def test_a_rerecord_batch_does_not_push_players_onto_the_fallback(
    db_sessionmaker,
):
    """Re-recording the cache after a voice change spends many days of budget
    at once (founder 2026-11-18, faster voice). Left out of today's spend, the
    budget keeps guarding what players spend, and nothing else."""
    from app.usage.elevenlabs_budget import exclude_from_today

    meter, now, clock = Meter(10_000), [_T0], [0.0]
    budget = _budget(db_sessionmaker, meter, now, clock)
    assert not await budget.exhausted()

    meter.used += 20 * BUDGET  # the batch
    await exclude_from_today(db_sessionmaker, 20 * BUDGET, meter.used, _T0.date())
    clock[0] += 61
    assert not await budget.exhausted()

    meter.used += BUDGET  # players still count
    clock[0] += 61
    assert await budget.exhausted()
