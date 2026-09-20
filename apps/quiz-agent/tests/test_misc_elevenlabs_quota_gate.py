"""Quota gate for POST /api/v1/elevenlabs/token (2026-09-20 outage).

With the ElevenLabs credit pool exhausted, token minting still succeeds but the
realtime Scribe socket fails mid-stream — the iOS client cannot detect that and
voice answers die silently. The route therefore checks remaining credits first
and 503s when they are below ELEVENLABS_MIN_CREDITS, which makes the client's
streaming setup fail loudly and fall back to batch Whisper. These tests pin:
(a) exhausted quota → 503, no token minted; (b) healthy quota → token minted;
(c) a failing subscription check never blocks minting (best-effort only).
"""

from __future__ import annotations

import httpx
import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient, MockTransport, Response
from fastapi import FastAPI

from app.api.routes import misc as misc_routes
from app.auth.tokens import TokenService
from app.rate_limit import limiter

pytestmark = pytest.mark.asyncio

_SECRET = "t" * 64


def _bearer() -> dict[str, str]:
    ts = TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )
    return {"Authorization": f"Bearer {ts.create_access_token('anon-test')}"}


def _mock_elevenlabs(monkeypatch, *, remaining: int | None, sub_error: bool = False):
    """Route httpx traffic to a fake ElevenLabs: subscription + token mint."""

    def handler(request: httpx.Request) -> Response:
        if request.url.path == "/v1/user/subscription":
            if sub_error:
                return Response(500, json={"detail": "boom"})
            return Response(
                200,
                json={
                    "character_limit": 10000,
                    "character_count": 10000 - (remaining or 0),
                },
            )
        if request.url.path == "/v1/single-use-token/realtime_scribe":
            return Response(200, json={"token": "fake-scribe-token"})
        return Response(404)

    transport = MockTransport(handler)
    real_init = httpx.AsyncClient.__init__

    def patched_init(self, *args, **kwargs):
        kwargs["transport"] = transport
        real_init(self, *args, **kwargs)

    monkeypatch.setattr(httpx.AsyncClient, "__init__", patched_init)


@pytest_asyncio.fixture
async def client(monkeypatch):
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    monkeypatch.setenv("ELEVENLABS_API_KEY", "fake-key")
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.include_router(misc_routes.router, prefix="/api/v1")
    app.state.token_service = TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def test_exhausted_quota_refuses_token(client, monkeypatch):
    _mock_elevenlabs(monkeypatch, remaining=12)
    resp = await client.post("/api/v1/elevenlabs/token", headers=_bearer())
    assert resp.status_code == 503
    assert "quota" in resp.json()["detail"].lower()


async def test_healthy_quota_mints_token(client, monkeypatch):
    _mock_elevenlabs(monkeypatch, remaining=9000)
    resp = await client.post("/api/v1/elevenlabs/token", headers=_bearer())
    assert resp.status_code == 200
    assert resp.json()["token"] == "fake-scribe-token"


async def test_subscription_check_failure_still_mints(client, monkeypatch):
    _mock_elevenlabs(monkeypatch, remaining=None, sub_error=True)
    resp = await client.post("/api/v1/elevenlabs/token", headers=_bearer())
    assert resp.status_code == 200
    assert resp.json()["token"] == "fake-scribe-token"
