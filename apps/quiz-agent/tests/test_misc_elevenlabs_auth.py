"""Auth + rate-limit gate for POST /api/v1/elevenlabs/token (#65).

This route mints a real, billable ElevenLabs realtime token and previously had
neither auth nor a rate limit — the clearest budget-drain vector. These pin
that it now (a) rejects unauthenticated callers when the grace window is off
and (b) caps a client to 10/min. The fixture removes ELEVENLABS_API_KEY so an
authed call deterministically 503s (proving the gate let it through to the body
without making a real upstream call) rather than hitting the network.
"""

from __future__ import annotations

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from fastapi import FastAPI
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.api.routes import misc as misc_routes
from app.auth.tokens import TokenService
from app.rate_limit import limiter

pytestmark = pytest.mark.asyncio

_SECRET = "t" * 64


def _token_service() -> TokenService:
    return TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )


def _bearer(subject: str = "anon-test") -> dict[str, str]:
    return {"Authorization": f"Bearer {_token_service().create_access_token(subject)}"}


@pytest_asyncio.fixture
async def client(monkeypatch):
    # Hard gate (grace off) + no upstream key → an authed call 503s deterministically.
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    monkeypatch.delenv("ELEVENLABS_API_KEY", raising=False)
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(misc_routes.router, prefix="/api/v1")
    app.state.token_service = _token_service()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def test_no_bearer_grace_off_rejected(client):
    resp = await client.post("/api/v1/elevenlabs/token")
    assert resp.status_code == 401


async def test_invalid_bearer_rejected(client):
    resp = await client.post(
        "/api/v1/elevenlabs/token", headers={"Authorization": "Bearer not-a-jwt"}
    )
    assert resp.status_code == 401


async def test_valid_bearer_reaches_route(client):
    """A valid bearer passes the gate — proven by the 503 from the missing
    ELEVENLABS_API_KEY (the body ran), which is *not* a 401."""
    resp = await client.post("/api/v1/elevenlabs/token", headers=_bearer())
    assert resp.status_code == 503


async def test_rate_limited_to_10_per_minute(client):
    """The 11th authed call within a minute is 429 (cap 10/min per client IP).
    Calls 1-10 reach the body and 503 on the missing key; the counter still
    increments, so the 11th trips the limiter before the body runs."""
    headers = _bearer()
    for _ in range(10):
        resp = await client.post("/api/v1/elevenlabs/token", headers=headers)
        assert resp.status_code == 503
    resp = await client.post("/api/v1/elevenlabs/token", headers=headers)
    assert resp.status_code == 429
