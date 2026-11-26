"""Monthly allowances as live admin switches (remote config, 2026-11-26).

Why these tests matter:
- The founder tunes the free and Plus allowances without an app release and
  without the env change that restarts the server mid-quiz. A switch must
  therefore change what the gate enforces on the very next question, not
  after a deploy or the 60 s cache.
- The paywall names the Plus allowance. ``/app-config`` serves the number the
  gate enforces, so the copy can never promise more than the player gets
  (App Review 3.1.2: a subscription must say clearly what it gives).
- A typo must be refused at write time: 0 free questions is a hard paywall
  (founder: never), 0 Plus questions locks out paying subscribers, and a
  boolean must never be stored as the number 1.
"""

from __future__ import annotations

from datetime import UTC, date, datetime

import pytest
from app import app_switches
from app.api.routes import app_config as app_config_routes
from app.usage.tracker import (
    FREE_MONTHLY_LIMIT,
    FREE_MONTHLY_VOICE_LIMIT,
    SUBSCRIBER_MONTHLY_LIMIT,
    UsageTracker,
)
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from tests.test_entitlement import SUBJECT, _seed_daily, _seed_subscription

pytestmark = pytest.mark.asyncio

KEY = "k"
_MID_MONTH = datetime(2026, 10, 15, 12, 0, tzinfo=UTC)
_MONTH_START = date(2026, 10, 1)


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("ADMIN_API_KEY", KEY)
    monkeypatch.setenv("RC_ALLOWED_ENVIRONMENT", "PRODUCTION")
    app_switches.reset_cache()
    yield
    app_switches.reset_cache()


def _client(sessionmaker) -> AsyncClient:
    app = FastAPI()
    app.include_router(app_config_routes.router, prefix="/api/v1")
    app.state.auth_sessionmaker = sessionmaker
    return AsyncClient(transport=ASGITransport(app=app), base_url="http://t")


async def _put(sessionmaker, body: dict):
    async with _client(sessionmaker) as c:
        return await c.put(
            "/api/v1/admin/app-switches", json=body, headers={"X-Admin-Key": KEY}
        )


async def _config(sessionmaker) -> dict:
    async with _client(sessionmaker) as c:
        resp = await c.get("/api/v1/app-config")
    assert resp.status_code == 200
    return resp.json()


def _tracker(sm) -> UsageTracker:
    """A production-shaped tracker: no pinned limits, so it reads the switches."""
    return UsageTracker(sm, now=lambda: _MID_MONTH)


async def test_without_a_switch_the_env_defaults_apply(db_sessionmaker):
    """No override row = exactly the plan sizes the gate used before."""
    body = await _config(db_sessionmaker)
    assert body["plus_monthly_questions"] == SUBSCRIBER_MONTHLY_LIMIT

    await _seed_daily(db_sessionmaker, FREE_MONTHLY_LIMIT - 1, usage_date=_MONTH_START)
    assert (await _tracker(db_sessionmaker).check_limit(SUBJECT))[:2] == (True, 1)


async def test_lowering_the_free_allowance_applies_on_the_next_question(
    db_sessionmaker,
):
    tracker = _tracker(db_sessionmaker)
    await _seed_daily(db_sessionmaker, 100, usage_date=_MONTH_START)
    # Warm the cache: the write must not wait for it to expire.
    assert (await tracker.check_limit(SUBJECT))[:2] == (True, FREE_MONTHLY_LIMIT - 100)

    resp = await _put(db_sessionmaker, {"set": {"free_monthly_questions": 100}})
    assert resp.status_code == 200, resp.text

    assert (await tracker.check_limit(SUBJECT))[0] is False
    usage = await tracker.get_usage(SUBJECT)
    assert (usage["questions_limit"], usage["remaining"]) == (100, 0)

    # Reset = back to the env default, still without a restart.
    await _put(db_sessionmaker, {"reset": ["free_monthly_questions"]})
    assert (await tracker.check_limit(SUBJECT))[:2] == (True, FREE_MONTHLY_LIMIT - 100)


async def test_plus_allowance_is_enforced_and_served_to_the_paywall(db_sessionmaker):
    """One number, two readers: what the subscriber gets and what the paywall
    promises must be the same, or the paywall misleads."""
    await _seed_subscription(
        db_sessionmaker, "active", expires_at=datetime(2026, 11, 15, tzinfo=UTC)
    )
    await _seed_daily(db_sessionmaker, 1000, usage_date=_MONTH_START)
    tracker = _tracker(db_sessionmaker)
    assert (await tracker.check_limit(SUBJECT))[0] is False

    await _put(db_sessionmaker, {"set": {"plus_monthly_questions": 1200}})

    assert (await tracker.check_limit(SUBJECT))[:2] == (True, 200)
    assert (await tracker.get_usage(SUBJECT))["questions_limit"] == 1200
    assert (await _config(db_sessionmaker))["plus_monthly_questions"] == 1200


async def test_voice_allowance_switch_reaches_the_voice_gate(db_sessionmaker):
    """Voice answers are the cost driver; 0 (no free voice) is a valid setting."""
    tracker = _tracker(db_sessionmaker)
    voice = await tracker.check_voice_answer(SUBJECT, "voice_answer:s:q")
    assert (voice.allowed, voice.limit) == (True, FREE_MONTHLY_VOICE_LIMIT)

    await _put(db_sessionmaker, {"set": {"free_monthly_voice_answers": 0}})

    voice = await tracker.check_voice_answer(SUBJECT, "voice_answer:s:q")
    assert (voice.allowed, voice.limit) == (False, 0)
    assert (await tracker.get_usage(SUBJECT))["voice_answers_limit"] == 0


@pytest.mark.parametrize(
    "change",
    [
        {"free_monthly_questions": 0},  # a hard paywall
        {"plus_monthly_questions": 0},  # subscribers locked out
        {"plus_monthly_questions": True},  # a bool, not a number
        {"free_monthly_questions": "150"},  # a string
        {"free_monthly_voice_answers": -1},
        {"plus_monthly_questions": 1.5},
        {"plus_monthly_questions": app_switches.INT_MAX + 1},
        {"free_monthly_questions": None},  # reset is the way back to env
    ],
)
async def test_bad_allowances_are_refused_and_nothing_is_written(
    db_sessionmaker, change
):
    resp = await _put(db_sessionmaker, {"set": change})

    assert resp.status_code == 422
    assert await app_switches.read_overrides(db_sessionmaker) == {}
