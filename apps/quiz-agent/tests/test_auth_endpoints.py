"""Tests for the /auth endpoints (issue #60, task 60.4 + 60.9).

These assert the HTTP contract on top of the already-unit-tested token/refresh
services: bootstrap mints a *verifiable* access JWT whose subject is the new
anon id and persists the identity row; refresh rotates and a replayed token is
rejected with 401 (so a leaked refresh token can't be reused); and the
endpoints fail safe with 503 when auth is unconfigured.
"""

from __future__ import annotations

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from fastapi import FastAPI
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from sqlalchemy import select

from app.api.routes import auth as auth_routes
from app.auth.refresh import RefreshTokenStore
from app.auth.tokens import TokenService
from app.db.models import AnonymousIdentity
from app.rate_limit import limiter

pytestmark = pytest.mark.asyncio

_SECRET = "t" * 64  # >= 64-char minimum enforced by TokenService
_ISSUER = "quiz-agent"
_AUDIENCE = "quiz-agent-clients"
_TTL = 900


def _token_service() -> TokenService:
    return TokenService(
        secret=_SECRET, issuer=_ISSUER, audience=_AUDIENCE, access_ttl_seconds=_TTL
    )


def _make_app(db_sessionmaker, *, auth_enabled: bool) -> FastAPI:
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(auth_routes.router, prefix="/api/v1")
    if auth_enabled:
        app.state.token_service = _token_service()
        app.state.refresh_store = RefreshTokenStore(
            db_sessionmaker, ttl_days=30, family_max_days=60
        )
        app.state.auth_sessionmaker = db_sessionmaker
    else:
        app.state.token_service = None
        app.state.refresh_store = None
        app.state.auth_sessionmaker = None
    return app


@pytest_asyncio.fixture
async def client(db_sessionmaker):
    # Shared in-memory limiter state leaks across tests — reset so a per-IP
    # counter from a prior test can't trip the 20/min bootstrap limit here.
    limiter.reset()
    app = _make_app(db_sessionmaker, auth_enabled=True)
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest_asyncio.fixture
async def disabled_client(db_sessionmaker):
    limiter.reset()
    app = _make_app(db_sessionmaker, auth_enabled=False)
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def _bootstrap(client) -> dict:
    resp = await client.post("/api/v1/auth/anon-bootstrap")
    assert resp.status_code == 200, resp.text
    return resp.json()


async def test_bootstrap_mints_verifiable_jwt_and_persists_identity(
    client, db_sessionmaker
):
    """Bootstrap returns a token pair, the access token verifies and its subject
    is the new anon id, and the identity row is actually persisted."""
    body = await _bootstrap(client)

    assert body["token_type"] == "bearer"
    assert body["expires_in"] == _TTL
    assert body["access_token"] and body["refresh_token"]
    anon_id = body["anon_id"]

    # The access token is a real, verifiable JWT for this subject.
    payload = _token_service().decode_access_token(body["access_token"])
    assert payload["sub"] == anon_id
    assert payload["iss"] == _ISSUER
    assert payload["aud"] == _AUDIENCE

    # The identity row exists in the DB.
    async with db_sessionmaker() as s:
        row = (
            await s.execute(
                select(AnonymousIdentity).where(AnonymousIdentity.anon_id == anon_id)
            )
        ).scalar_one_or_none()
    assert row is not None and row.is_legacy is False


async def test_refresh_rotates_to_a_new_pair(client):
    body = await _bootstrap(client)
    resp = await client.post(
        "/api/v1/auth/refresh", json={"refresh_token": body["refresh_token"]}
    )
    assert resp.status_code == 200, resp.text
    rotated = resp.json()

    assert rotated["refresh_token"] != body["refresh_token"]  # rotated
    assert rotated["access_token"]  # fresh access token
    assert rotated["anon_id"] == body["anon_id"]  # same subject


async def test_replayed_refresh_token_is_rejected(client):
    """A refresh token is single-use: presenting it after rotation → 401. This
    is the theft guard — a leaked-but-already-used token is worthless."""
    body = await _bootstrap(client)
    first = body["refresh_token"]

    await client.post("/api/v1/auth/refresh", json={"refresh_token": first})  # consumes
    replay = await client.post("/api/v1/auth/refresh", json={"refresh_token": first})
    assert replay.status_code == 401


async def test_reuse_revokes_family_so_latest_token_also_401(client):
    """After reuse is detected the whole family is revoked, so even the latest
    (otherwise valid) token stops working — containment, not single-token kill."""
    body = await _bootstrap(client)
    first = body["refresh_token"]
    rotated = (
        await client.post("/api/v1/auth/refresh", json={"refresh_token": first})
    ).json()

    # Replay the consumed token → triggers family revocation.
    replay = await client.post("/api/v1/auth/refresh", json={"refresh_token": first})
    assert replay.status_code == 401

    # The latest token, valid a moment ago, is now revoked too.
    latest = await client.post(
        "/api/v1/auth/refresh", json={"refresh_token": rotated["refresh_token"]}
    )
    assert latest.status_code == 401


async def test_unknown_refresh_token_is_rejected(client):
    resp = await client.post(
        "/api/v1/auth/refresh", json={"refresh_token": "not-a-real-token"}
    )
    assert resp.status_code == 401


async def test_logout_revokes_the_family_so_the_token_stops_working(client):
    """Sign-out must kill the session server-side: a refresh token extracted
    from the device before sign-out would otherwise stay valid for its full TTL
    and keep minting sessions for whoever holds it."""
    body = await _bootstrap(client)

    resp = await client.post(
        "/api/v1/auth/logout", json={"refresh_token": body["refresh_token"]}
    )
    assert resp.status_code == 204

    # The signed-out token can no longer refresh.
    after = await client.post(
        "/api/v1/auth/refresh", json={"refresh_token": body["refresh_token"]}
    )
    assert after.status_code == 401


async def test_logout_is_idempotent_and_silent_on_unknown_tokens(client):
    """204 for a garbage or double-logout token — the response must never reveal
    whether a guessed token was valid."""
    body = await _bootstrap(client)

    first = await client.post(
        "/api/v1/auth/logout", json={"refresh_token": body["refresh_token"]}
    )
    second = await client.post(
        "/api/v1/auth/logout", json={"refresh_token": body["refresh_token"]}
    )
    garbage = await client.post(
        "/api/v1/auth/logout", json={"refresh_token": "not-a-real-token"}
    )
    assert first.status_code == second.status_code == garbage.status_code == 204


async def test_endpoints_503_when_auth_disabled(disabled_client):
    """Without a JWT secret / DB the endpoints must fail safe (503), never mint
    tokens an unconfigured service can't verify."""
    boot = await disabled_client.post("/api/v1/auth/anon-bootstrap")
    assert boot.status_code == 503

    refresh = await disabled_client.post(
        "/api/v1/auth/refresh", json={"refresh_token": "x"}
    )
    assert refresh.status_code == 503

    logout = await disabled_client.post(
        "/api/v1/auth/logout", json={"refresh_token": "x"}
    )
    assert logout.status_code == 503
