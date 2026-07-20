"""Regression: rate-limit buckets key on the real client IP, not the Fly proxy (#65).

Before #65 the limiter used ``get_remote_address``, which on Fly.io returns the
proxy address — collapsing every per-IP limit into one global bucket (so one
abuser could exhaust everyone's quota, and distinct clients shared a counter).

Two angles, deliberately isolated from slowapi's shared in-memory state:
1. a fresh limiter keyed on ``fly_client_ip`` gives distinct IPs independent
   counters;
2. the production ``limiter`` is wired to that key function, so every existing
   ``@limiter.limit`` decorator inherits the fix.

The key function itself (``fly_client_ip`` — prefers ``Fly-Client-IP``, falls
back to the peer address off-Fly) is unit-tested once for both apps in
``packages/shared/tests/test_net_util.py`` since it moved to
``quiz_shared.net.util`` (backend arch review 2026-07-18).
"""

from __future__ import annotations

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from fastapi import FastAPI, Request
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.rate_limit import fly_client_ip, limiter


# The production limiter is keyed on it ---------------------------------------


def test_production_limiter_keyed_on_fly_client_ip() -> None:
    """Pins the actual fix: re-keying the shared limiter re-keys every decorator."""
    assert limiter._key_func is fly_client_ip


# Behavioral: distinct IPs → independent buckets ------------------------------
# Uses a *fresh* Limiter (its own storage) so the shared module limiter's state
# can't leak between tests and make this flaky.


@pytest_asyncio.fixture
async def client():
    test_limiter = Limiter(key_func=fly_client_ip)
    app = FastAPI()
    app.state.limiter = test_limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

    @app.get("/ping")
    @test_limiter.limit("1/minute")
    async def ping(request: Request):
        return {"ok": True}

    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c


@pytest.mark.asyncio
async def test_same_client_ip_shares_bucket(client):
    headers = {"Fly-Client-IP": "1.2.3.4"}
    first = await client.get("/ping", headers=headers)
    second = await client.get("/ping", headers=headers)
    assert first.status_code == 200
    assert second.status_code == 429  # same IP → one bucket, limit 1/min


@pytest.mark.asyncio
async def test_different_client_ip_independent_bucket(client):
    first = await client.get("/ping", headers={"Fly-Client-IP": "1.2.3.4"})
    other = await client.get("/ping", headers={"Fly-Client-IP": "5.6.7.8"})
    assert first.status_code == 200
    # Distinct IP → fresh bucket. Under the old global-bucket bug this was the
    # 2nd request overall and would have been 429.
    assert other.status_code == 200
