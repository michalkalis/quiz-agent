"""Tests for App Attest challenges (issue #60 Part B, task 60.10).

A challenge is the server-issued nonce that makes App Attest replay-proof, so
the security-relevant properties are: it is single-use (a spent challenge can
never back a second verification), it expires, and the HTTP endpoint actually
persists one and fails safe (503) when App Attest is unconfigured.
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
from app.auth.attest_challenge import ChallengeError, ChallengeStore
from app.db.models import AttestChallenge
from app.rate_limit import limiter

pytestmark = pytest.mark.asyncio


# ── Store-level: the single-use + TTL guarantees ─────────────────────────────


async def test_issue_persists_a_unique_challenge(db_sessionmaker):
    store = ChallengeStore(db_sessionmaker, ttl_seconds=300)
    a = await store.issue()
    b = await store.issue()

    assert a and b and a != b  # high-entropy, distinct each call
    async with db_sessionmaker() as s:
        rows = (await s.execute(select(AttestChallenge))).scalars().all()
    assert {r.challenge for r in rows} == {a, b}
    assert all(r.used_at is None for r in rows)


async def test_consume_spends_a_challenge_exactly_once(db_sessionmaker):
    """The core replay guard: a challenge backs at most one verification."""
    store = ChallengeStore(db_sessionmaker, ttl_seconds=300)
    challenge = await store.issue()

    await store.consume(challenge)  # first use succeeds
    with pytest.raises(ChallengeError):
        await store.consume(challenge)  # replay rejected

    async with db_sessionmaker() as s:
        row = (
            await s.execute(
                select(AttestChallenge).where(AttestChallenge.challenge == challenge)
            )
        ).scalar_one()
    assert row.used_at is not None


async def test_consume_unknown_challenge_is_rejected(db_sessionmaker):
    store = ChallengeStore(db_sessionmaker, ttl_seconds=300)
    with pytest.raises(ChallengeError):
        await store.consume("never-issued")


async def test_consume_expired_challenge_is_rejected(db_sessionmaker):
    """An expired challenge cannot be spent even if it was never used — the TTL
    bounds the window in which a captured challenge is worth anything."""
    store = ChallengeStore(db_sessionmaker, ttl_seconds=-1)  # already expired
    challenge = await store.issue()
    with pytest.raises(ChallengeError):
        await store.consume(challenge)


# ── HTTP: the endpoint contract ──────────────────────────────────────────────


def _make_app(db_sessionmaker, *, enabled: bool) -> FastAPI:
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(auth_routes.router, prefix="/api/v1")
    app.state.challenge_store = (
        ChallengeStore(db_sessionmaker, ttl_seconds=300) if enabled else None
    )
    return app


@pytest_asyncio.fixture
async def client(db_sessionmaker):
    limiter.reset()
    transport = ASGITransport(app=_make_app(db_sessionmaker, enabled=True))
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest_asyncio.fixture
async def disabled_client(db_sessionmaker):
    limiter.reset()
    transport = ASGITransport(app=_make_app(db_sessionmaker, enabled=False))
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def test_endpoint_returns_and_persists_a_challenge(client, db_sessionmaker):
    resp = await client.post("/api/v1/auth/attest-challenge")
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["challenge"] and body["expires_in"] == 300

    async with db_sessionmaker() as s:
        row = (
            await s.execute(
                select(AttestChallenge).where(
                    AttestChallenge.challenge == body["challenge"]
                )
            )
        ).scalar_one_or_none()
    assert row is not None and row.used_at is None


async def test_endpoint_503_when_disabled(disabled_client):
    """Without a DB the endpoint fails safe, like the other auth endpoints."""
    resp = await disabled_client.post("/api/v1/auth/attest-challenge")
    assert resp.status_code == 503
