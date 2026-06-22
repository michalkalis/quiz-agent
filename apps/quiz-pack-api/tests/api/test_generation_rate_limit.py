"""Rate limit on the billable generation/verify routes (#65).

`/generate`, `/generate/advanced`, `/verify`, `/verify/batch` call gpt-4o /
Tavily per request. They are admin-key gated, but a leaked key would otherwise
allow unbounded billable calls — so each carries a 10/min-per-client-IP cap as
defense-in-depth. This pins that cap on `/generate/advanced`: the generator is
stubbed so the 10 passing calls make no real LLM call, and the 11th trips the
limiter (429) before the body runs. A second test binds the shared limiter to
the IP-discriminating key function, so the cap is per real client, not per Fly
proxy (matching the quiz-agent fix).
"""

from __future__ import annotations

from typing import AsyncIterator

import httpx
import pytest_asyncio
from fastapi import FastAPI
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.api import routes as routes_module
from app.api.deps import get_settings
from app.api.routes import router as questions_router
from app.config import Settings
from app.rate_limit import fly_client_ip, limiter

_KEY = {"X-Admin-Key": "testkey"}


@pytest_asyncio.fixture
async def client(monkeypatch) -> AsyncIterator[httpx.AsyncClient]:
    # Stub the LLM so the 10 allowed calls cost nothing and hit no network.
    async def _no_llm(**kwargs):
        return []

    monkeypatch.setattr(routes_module.advanced_generator, "generate_questions", _no_llm)
    limiter.reset()  # shared module singleton — clear any prior test's window

    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(questions_router)
    app.dependency_overrides[get_settings] = lambda: Settings(admin_api_key="testkey")

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app),
        base_url="http://test",
    ) as ac:
        yield ac


async def test_generate_advanced_rate_limited_to_10_per_minute(client) -> None:
    """11th authed call within a minute is 429 (cap 10/min per client IP).
    require_admin passes (valid key) and the stubbed generator returns []."""
    for _ in range(10):
        resp = await client.post("/api/v1/generate/advanced", json={}, headers=_KEY)
        assert resp.status_code == 200
    resp = await client.post("/api/v1/generate/advanced", json={}, headers=_KEY)
    assert resp.status_code == 429


async def test_limiter_keyed_on_fly_client_ip() -> None:
    """The cap is per real client IP, not per Fly proxy — same fix as quiz-agent."""
    assert limiter._key_func is fly_client_ip
