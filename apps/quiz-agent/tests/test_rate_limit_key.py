"""Regression: rate-limit buckets key on the real client IP, not the Fly proxy (#65).

Before #65 the limiter used ``get_remote_address``, which on Fly.io returns the
proxy address — collapsing every per-IP limit into one global bucket (so one
abuser could exhaust everyone's quota, and distinct clients shared a counter).

Three angles, deliberately isolated from slowapi's shared in-memory state:
1. the ``fly_client_ip`` key function itself prefers ``Fly-Client-IP`` and falls
   back to the peer address off-Fly (this *is* the one-line fix);
2. a fresh limiter keyed on it gives distinct IPs independent counters;
3. the production ``limiter`` is wired to that key function, so every existing
   ``@limiter.limit`` decorator inherits the fix.
"""

from __future__ import annotations

from types import SimpleNamespace

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from fastapi import FastAPI, Request
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.rate_limit import fly_client_ip, limiter


class _Req:
    """Minimal Request stand-in: ``.headers`` and ``.client`` (read by get_remote_address)."""

    def __init__(self, fly_ip: str | None = None, peer: str | None = None) -> None:
        self.headers = {} if fly_ip is None else {"Fly-Client-IP": fly_ip}
        self.client = SimpleNamespace(host=peer) if peer else None


# 1. The key function ---------------------------------------------------------


def test_fly_client_ip_prefers_header() -> None:
    """On Fly the key is the real client IP from Fly-Client-IP, not the peer."""
    assert fly_client_ip(_Req(fly_ip="9.9.9.9", peer="10.0.0.1")) == "9.9.9.9"


def test_fly_client_ip_falls_back_to_peer_off_fly() -> None:
    """Off Fly (no header — local dev / tests) it falls back to the peer addr."""
    assert fly_client_ip(_Req(fly_ip=None, peer="10.0.0.1")) == "10.0.0.1"


# 3. The production limiter is keyed on it ------------------------------------


def test_production_limiter_keyed_on_fly_client_ip() -> None:
    """Pins the actual fix: re-keying the shared limiter re-keys every decorator."""
    assert limiter._key_func is fly_client_ip


# 2. Behavioral: distinct IPs → independent buckets ---------------------------
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
