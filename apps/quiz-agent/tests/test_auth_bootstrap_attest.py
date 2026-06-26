"""HTTP gating of anon-bootstrap on App Attest (issue #60 Part B, task 60.12).

The verifier itself is unit-tested in ``test_app_attest.py``; this file asserts
the *endpoint policy* layered on top:

- with ``APP_ATTEST_REQUIRED`` off, bootstrap still mints plainly (the Part A
  client and the dev/sim path keep working);
- with it on, a bootstrap carrying no usable attestation/assertion is rejected,
  and a misconfigured server (flag on, verifier absent) fails safe with 503;
- a first-launch **attestation** mints an identity and binds the Secure-Enclave
  key to it 1:1; an ongoing **assertion** re-issues tokens for that *same*
  identity and never mints a new one;
- replaying an assertion (non-advancing counter) is rejected.

These map directly onto the Part B acceptance checklist in issue-60.
"""

from __future__ import annotations

import base64

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from fastapi import FastAPI
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from sqlalchemy import func, select

from app.api.routes import auth as auth_routes
from app.auth.app_attest import AppAttestService
from app.auth.attest_challenge import ChallengeStore
from app.auth.refresh import RefreshTokenStore
from app.auth.tokens import TokenService
from app.db.models import AnonymousIdentity, AppAttestKey
from app.rate_limit import limiter

# Reuse the synthetic attestation/assertion builders + the test root CA.
from tests.test_app_attest import (
    APP_ID,
    build_assertion,
    build_attestation,
    _build_root,
)

pytestmark = pytest.mark.asyncio

_SECRET = "t" * 64


def _token_service() -> TokenService:
    return TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )


def _make_app(db_sessionmaker, *, attest_service) -> FastAPI:
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(auth_routes.router, prefix="/api/v1")
    app.state.token_service = _token_service()
    app.state.refresh_store = RefreshTokenStore(
        db_sessionmaker, ttl_days=30, family_max_days=60
    )
    app.state.auth_sessionmaker = db_sessionmaker
    app.state.app_attest_service = attest_service
    return app


@pytest.fixture(scope="module")
def root():
    return _build_root()  # (key, cert, pem)


def _service(db_sessionmaker, root_pem):
    """An AppAttestService + its ChallengeStore wired to the test root CA."""
    store = ChallengeStore(db_sessionmaker, ttl_seconds=300)
    svc = AppAttestService(
        db_sessionmaker,
        store,
        app_id=APP_ID,
        environment="development",
        root_ca=root_pem,
    )
    return svc, store


@pytest_asyncio.fixture
async def attested_client(db_sessionmaker, root):
    """Client with the verifier wired in, plus a handle to its challenge store
    so a test can hand the 'device' a fresh challenge."""
    limiter.reset()
    _, _, root_pem = root
    svc, store = _service(db_sessionmaker, root_pem)
    app = _make_app(db_sessionmaker, attest_service=svc)
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c, store


@pytest_asyncio.fixture
async def unattested_client(db_sessionmaker):
    """Client with no verifier configured (app_attest_service is None)."""
    limiter.reset()
    app = _make_app(db_sessionmaker, attest_service=None)
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def _identity_count(db_sessionmaker) -> int:
    async with db_sessionmaker() as s:
        return (await s.execute(select(func.count(AnonymousIdentity.anon_id)))).scalar()


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode()


# ── Flag off: the dev/sim/Part-A path is untouched ───────────────────────────


async def test_bootstrap_mints_plainly_when_attest_not_required(
    unattested_client, monkeypatch
):
    monkeypatch.delenv("APP_ATTEST_REQUIRED", raising=False)  # default off
    resp = await unattested_client.post("/api/v1/auth/anon-bootstrap")
    assert resp.status_code == 200, resp.text
    assert resp.json()["anon_id"]


# ── Flag on: a credential is mandatory ───────────────────────────────────────


async def test_bootstrap_rejected_when_required_and_no_credential(
    attested_client, monkeypatch
):
    monkeypatch.setenv("APP_ATTEST_REQUIRED", "true")
    client, _ = attested_client
    resp = await client.post("/api/v1/auth/anon-bootstrap")
    assert resp.status_code == 401, resp.text


async def test_bootstrap_503_when_required_but_verifier_unconfigured(
    unattested_client, monkeypatch
):
    """Flag on but no APP_ATTEST_APP_ID (service is None): fail safe, never fall
    back to minting unattested identities."""
    monkeypatch.setenv("APP_ATTEST_REQUIRED", "true")
    resp = await unattested_client.post("/api/v1/auth/anon-bootstrap")
    assert resp.status_code == 503, resp.text


# ── Attestation: first launch mints + binds the key 1:1 ──────────────────────


async def test_attestation_bootstrap_mints_and_binds_key(
    attested_client, db_sessionmaker, root, monkeypatch
):
    monkeypatch.setenv("APP_ATTEST_REQUIRED", "true")
    client, store = attested_client
    root_key, root_cert, _ = root
    before = await _identity_count(db_sessionmaker)

    challenge = await store.issue()
    attestation, key_id_b64, _ = build_attestation(challenge, root_key, root_cert)
    resp = await client.post(
        "/api/v1/auth/anon-bootstrap",
        json={
            "key_id": key_id_b64,
            "attestation": _b64(attestation),
            "challenge": challenge,
        },
    )
    assert resp.status_code == 200, resp.text
    anon_id = resp.json()["anon_id"]
    assert await _identity_count(db_sessionmaker) == before + 1

    # The attested key is now bound to exactly this identity.
    async with db_sessionmaker() as s:
        key = (
            await s.execute(
                select(AppAttestKey).where(AppAttestKey.key_id == key_id_b64)
            )
        ).scalar_one()
    assert key.anon_id == anon_id
    assert key.sign_counter == 0


async def test_attestation_bootstrap_rejected_for_spent_challenge(
    attested_client, db_sessionmaker, root, monkeypatch
):
    """A captured attestation is worthless once its challenge is spent — and the
    rejection mints no identity."""
    monkeypatch.setenv("APP_ATTEST_REQUIRED", "true")
    client, store = attested_client
    root_key, root_cert, _ = root
    before = await _identity_count(db_sessionmaker)

    challenge = await store.issue()
    attestation, key_id_b64, _ = build_attestation(challenge, root_key, root_cert)
    await store.consume(challenge)  # already spent

    resp = await client.post(
        "/api/v1/auth/anon-bootstrap",
        json={
            "key_id": key_id_b64,
            "attestation": _b64(attestation),
            "challenge": challenge,
        },
    )
    assert resp.status_code == 401, resp.text
    assert await _identity_count(db_sessionmaker) == before  # nothing minted


# ── Assertion: re-bootstrap re-issues the SAME identity ──────────────────────


async def _attest_bootstrap(client, store, root_key, root_cert):
    challenge = await store.issue()
    attestation, key_id_b64, leaf_key = build_attestation(
        challenge, root_key, root_cert
    )
    resp = await client.post(
        "/api/v1/auth/anon-bootstrap",
        json={
            "key_id": key_id_b64,
            "attestation": _b64(attestation),
            "challenge": challenge,
        },
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["anon_id"], key_id_b64, leaf_key


async def test_assertion_bootstrap_reissues_same_identity(
    attested_client, db_sessionmaker, root, monkeypatch
):
    monkeypatch.setenv("APP_ATTEST_REQUIRED", "true")
    client, store = attested_client
    root_key, root_cert, _ = root

    anon_id, key_id_b64, leaf_key = await _attest_bootstrap(
        client, store, root_key, root_cert
    )
    before = await _identity_count(db_sessionmaker)

    challenge = await store.issue()
    assertion = build_assertion(challenge, leaf_key, counter=5)
    resp = await client.post(
        "/api/v1/auth/anon-bootstrap",
        json={
            "key_id": key_id_b64,
            "assertion": _b64(assertion),
            "challenge": challenge,
        },
    )
    assert resp.status_code == 200, resp.text
    # Same device key → same identity, and no new identity row was created.
    assert resp.json()["anon_id"] == anon_id
    assert await _identity_count(db_sessionmaker) == before


async def test_assertion_bootstrap_replay_rejected(attested_client, root, monkeypatch):
    monkeypatch.setenv("APP_ATTEST_REQUIRED", "true")
    client, store = attested_client
    root_key, root_cert, _ = root

    _, key_id_b64, leaf_key = await _attest_bootstrap(
        client, store, root_key, root_cert
    )

    # Advance the counter to 7.
    c1 = await store.issue()
    ok = await client.post(
        "/api/v1/auth/anon-bootstrap",
        json={
            "key_id": key_id_b64,
            "assertion": _b64(build_assertion(c1, leaf_key, counter=7)),
            "challenge": c1,
        },
    )
    assert ok.status_code == 200, ok.text

    # Replay at the same counter (fresh challenge) → rejected.
    c2 = await store.issue()
    replay = await client.post(
        "/api/v1/auth/anon-bootstrap",
        json={
            "key_id": key_id_b64,
            "assertion": _b64(build_assertion(c2, leaf_key, counter=7)),
            "challenge": c2,
        },
    )
    assert replay.status_code == 401, replay.text


async def test_assertion_for_unknown_key_rejected(attested_client, root, monkeypatch):
    """An assertion for a key that was never attested has no identity to
    re-issue, so it is rejected rather than minting one."""
    monkeypatch.setenv("APP_ATTEST_REQUIRED", "true")
    client, store = attested_client
    from cryptography.hazmat.primitives.asymmetric import ec

    stranger = ec.generate_private_key(ec.SECP256R1())
    challenge = await store.issue()
    assertion = build_assertion(challenge, stranger, counter=1)
    resp = await client.post(
        "/api/v1/auth/anon-bootstrap",
        json={
            "key_id": "never-attested",
            "assertion": _b64(assertion),
            "challenge": challenge,
        },
    )
    assert resp.status_code == 401, resp.text
