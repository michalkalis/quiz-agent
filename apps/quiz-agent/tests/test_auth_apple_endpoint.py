"""Integration tests for POST /auth/apple — Sign in with Apple (issue #61, 61.4).

The endpoint is the upgrade seam from an anonymous identity to a real account, so
the contract these pin is the *anti-abuse + correctness core* of decision F3, not
just a 200:

- the freemium usage of the anonymous caller is **summed** into the account, so
  signing out → fresh anon → signing back in can never reset the daily limit
  (sum, not max);
- the upgrade is **idempotent** (a replayed call never double-counts);
- an anon already claimed by a *different* account is rejected (409);
- a bad Apple identity token is rejected (401) and never creates an account;
- the returned JWT's subject is ``users.id`` (the durable account anchor), and
- Apple's refresh token is stored **encrypted at rest** (F1/F2), or null when
  Apple returns none.

Apple is fully mocked: a throwaway RSA keypair signs synthetic id_tokens and an
``httpx.MockTransport`` stubs both Apple's JWKS and its token endpoint — no
network. The auth tables use the real test Postgres via ``db_sessionmaker``.
"""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timedelta, timezone

import httpx
import jwt
import pytest
import pytest_asyncio
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from jwt.algorithms import RSAAlgorithm
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from sqlalchemy import select

from app.api.routes import auth as auth_routes
from app.auth.apple import AppleIdentityVerifier, expected_nonce_claim
from app.auth.apple_oauth import AppleOAuthClient
from app.auth.apple_secrets import AppleTokenCipher
from app.auth.refresh import RefreshTokenStore
from app.auth.tokens import TokenService
from app.db.models import AnonymousIdentity, DailyUsage, User
from app.rate_limit import limiter

pytestmark = pytest.mark.asyncio

AUDIENCE = "com.missinghue.hangs"  # native SIWA → aud is the app bundle id
ISSUER = "https://appleid.apple.com"
JWKS_URL = "https://appleid.apple.com/auth/keys"
KID = "test-kid"
RAW_NONCE = "raw-nonce-the-client-generated-0123456789ab"

_SECRET = "t" * 64
_JWT_ISSUER = "quiz-agent"
_JWT_AUDIENCE = "quiz-agent-clients"
_TTL = 900
TEAM_ID = "KAGWHPZZFQ"
KEY_ID = "ABC123KEYID"
ENC_KEY = Fernet.generate_key()
APPLE_REFRESH = "apple-refresh-token-xyz"


def _today():
    return datetime.now(timezone.utc).date()


def _token_service() -> TokenService:
    return TokenService(
        secret=_SECRET,
        issuer=_JWT_ISSUER,
        audience=_JWT_AUDIENCE,
        access_ttl_seconds=_TTL,
    )


# ── Synthetic Apple id_token + JWKS + token-exchange stubs ───────────────────


@pytest.fixture(scope="module")
def keypair() -> rsa.RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _jwks(public_key) -> dict:
    jwk = json.loads(RSAAlgorithm.to_jwk(public_key))
    jwk.update({"kid": KID, "alg": "RS256", "use": "sig"})
    return {"keys": [jwk]}


def _jwks_client(public_key) -> httpx.AsyncClient:
    jwks = _jwks(public_key)
    return httpx.AsyncClient(
        transport=httpx.MockTransport(lambda req: httpx.Response(200, json=jwks))
    )


def _id_token(key: rsa.RSAPrivateKey, *, sub: str, raw_nonce: str = RAW_NONCE) -> str:
    now = datetime.now(timezone.utc)
    claims = {
        "iss": ISSUER,
        "aud": AUDIENCE,
        "sub": sub,
        "iat": now,
        "exp": now + timedelta(minutes=10),
        "email": f"{sub}@privaterelay.appleid.com",
        "nonce": expected_nonce_claim(raw_nonce),
    }
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": KID})


def _es256_pem() -> str:
    key = ec.generate_private_key(ec.SECP256R1())
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()


_P8 = _es256_pem()


def _token_exchange_client(
    refresh_token: str | None = APPLE_REFRESH,
) -> httpx.AsyncClient:
    def handler(req: httpx.Request) -> httpx.Response:
        payload = {"access_token": "a", "token_type": "Bearer", "expires_in": 3600}
        if refresh_token is not None:
            payload["refresh_token"] = refresh_token
        return httpx.Response(200, json=payload)

    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


# ── App wiring (mirrors test_auth_endpoints, plus the Apple services) ─────────


def _make_app(
    db_sessionmaker,
    public_key,
    *,
    apple_configured: bool = True,
    apple_refresh: str | None = APPLE_REFRESH,
) -> FastAPI:
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(auth_routes.router, prefix="/api/v1")
    app.state.token_service = _token_service()
    app.state.refresh_store = RefreshTokenStore(
        db_sessionmaker, ttl_days=30, family_max_days=60
    )
    app.state.auth_sessionmaker = db_sessionmaker
    if apple_configured:
        app.state.apple_verifier = AppleIdentityVerifier(
            audience=AUDIENCE, http_client=_jwks_client(public_key)
        )
        app.state.apple_oauth_client = AppleOAuthClient(
            team_id=TEAM_ID,
            client_id=AUDIENCE,
            key_id=KEY_ID,
            private_key=_P8,
            http_client=_token_exchange_client(apple_refresh),
        )
        app.state.apple_token_cipher = AppleTokenCipher(ENC_KEY)
    else:
        app.state.apple_verifier = None
        app.state.apple_oauth_client = None
        app.state.apple_token_cipher = None
    return app


@pytest_asyncio.fixture
async def client(db_sessionmaker, keypair):
    limiter.reset()
    app = _make_app(db_sessionmaker, keypair.public_key())
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c


# ── DB helpers ───────────────────────────────────────────────────────────────


async def _make_anon(db) -> tuple[str, str]:
    """Insert an anonymous identity row + return (anon_id, a bearer for it)."""
    anon_id = str(uuid.uuid4())
    async with db() as s:
        s.add(AnonymousIdentity(anon_id=anon_id))
        await s.commit()
    return anon_id, _token_service().create_access_token(anon_id)


async def _seed_usage(
    db, subject_id: str, count: int, *, premium: bool = False
) -> None:
    async with db() as s:
        s.add(
            DailyUsage(
                subject_id=subject_id,
                usage_date=_today(),
                questions_count=count,
                is_premium=premium,
            )
        )
        await s.commit()


async def _usage_today(db, subject_id: str) -> int | None:
    async with db() as s:
        row = (
            await s.execute(
                select(DailyUsage).where(
                    DailyUsage.subject_id == subject_id,
                    DailyUsage.usage_date == _today(),
                )
            )
        ).scalar_one_or_none()
    return row.questions_count if row else None


async def _get_user(db, apple_sub: str) -> User | None:
    async with db() as s:
        return (
            await s.execute(select(User).where(User.apple_sub == apple_sub))
        ).scalar_one_or_none()


async def _get_anon(db, anon_id: str) -> AnonymousIdentity | None:
    async with db() as s:
        return (
            await s.execute(
                select(AnonymousIdentity).where(AnonymousIdentity.anon_id == anon_id)
            )
        ).scalar_one_or_none()


async def _call_apple(
    client,
    key,
    *,
    sub: str,
    bearer: str | None = None,
    raw_nonce: str = RAW_NONCE,
    code: str = "auth-code",
    user: dict | None = None,
    identity_token: str | None = None,
):
    if identity_token is None:
        identity_token = _id_token(key, sub=sub)
    body = {
        "identity_token": identity_token,
        "authorization_code": code,
        "raw_nonce": raw_nonce,
    }
    if user is not None:
        body["user"] = user
    headers = {"Authorization": f"Bearer {bearer}"} if bearer else {}
    return await client.post("/api/v1/auth/apple", json=body, headers=headers)


# ── Happy path: account creation + usage fold + subject = users.id ───────────


async def test_happy_path_creates_account_folds_usage_and_returns_user_subject(
    client, keypair, db_sessionmaker
):
    anon_id, bearer = await _make_anon(db_sessionmaker)
    await _seed_usage(db_sessionmaker, anon_id, 3)

    resp = await _call_apple(
        client,
        keypair,
        sub="apple.sub.0001",
        bearer=bearer,
        user={"name": "Jan Novak", "email": "client-supplied@x.sk"},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()

    user = await _get_user(db_sessionmaker, "apple.sub.0001")
    assert user is not None
    # The returned subject is the account id, and the access token verifies to it.
    assert body["anon_id"] == str(user.id)
    payload = _token_service().decode_access_token(body["access_token"])
    assert payload["sub"] == str(user.id)
    assert body["refresh_token"] and body["token_type"] == "bearer"

    # F5: the Apple name is stored. Email prefers the *verified* id_token claim
    # over the client-supplied body value.
    assert user.full_name == "Jan Novak"
    assert user.email == "apple.sub.0001@privaterelay.appleid.com"

    # The anon's usage was folded into the account, and the anon is marked upgraded.
    assert await _usage_today(db_sessionmaker, str(user.id)) == 3
    # The anon's own rows are KEPT (frozen): the device's App Attest key returns
    # it to this subject after sign-out/delete — dropping the rows here would
    # make that return trip a free daily-limit reset.
    assert await _usage_today(db_sessionmaker, anon_id) == 3
    anon = await _get_anon(db_sessionmaker, anon_id)
    assert anon.upgraded_to_user_id == str(user.id)


async def test_apple_refresh_token_is_stored_encrypted(
    client, keypair, db_sessionmaker
):
    """F1/F2: Apple's refresh token never touches the DB in the clear — the column
    is Fernet ciphertext that decrypts back to what Apple returned."""
    _, bearer = await _make_anon(db_sessionmaker)
    resp = await _call_apple(client, keypair, sub="apple.sub.enc", bearer=bearer)
    assert resp.status_code == 200, resp.text

    user = await _get_user(db_sessionmaker, "apple.sub.enc")
    assert user.apple_refresh_token_encrypted is not None
    assert user.apple_refresh_token_encrypted != APPLE_REFRESH.encode()  # not plaintext
    assert AppleTokenCipher(ENC_KEY).decrypt(user.apple_refresh_token_encrypted) == (
        APPLE_REFRESH
    )


async def test_no_apple_refresh_token_stores_null(db_sessionmaker, keypair):
    """Apple does not always return a refresh token; then the column stays null
    (Session C falls back to the no-token revoke) — sign-in still succeeds."""
    limiter.reset()
    app = _make_app(db_sessionmaker, keypair.public_key(), apple_refresh=None)
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        _, bearer = await _make_anon(db_sessionmaker)
        resp = await _call_apple(c, keypair, sub="apple.sub.norefresh", bearer=bearer)
    assert resp.status_code == 200, resp.text
    user = await _get_user(db_sessionmaker, "apple.sub.norefresh")
    assert user.apple_refresh_token_encrypted is None


# ── F3 core: sum not max, idempotency, freemium cannot be reset ──────────────


async def test_sign_out_fresh_anon_sign_in_sums_usage_and_cannot_reset_limit(
    client, keypair, db_sessionmaker
):
    """The decisive F3 test: a returning user's prior usage (7) plus the usage of
    the fresh anon they used while signed out (5) is **12** — summed, not maxed
    (would be 7) and not reset to the fresh anon's count (5). This is what makes
    signing out and back in unable to hand out a fresh freemium bucket."""
    anon1, bearer1 = await _make_anon(db_sessionmaker)
    await _seed_usage(db_sessionmaker, anon1, 7)
    r1 = await _call_apple(client, keypair, sub="apple.sub.same", bearer=bearer1)
    assert r1.status_code == 200, r1.text
    user_id = r1.json()["anon_id"]
    assert await _usage_today(db_sessionmaker, user_id) == 7

    # Signed out → a brand-new anon identity that used 5 questions.
    anon2, bearer2 = await _make_anon(db_sessionmaker)
    await _seed_usage(db_sessionmaker, anon2, 5)
    r2 = await _call_apple(client, keypair, sub="apple.sub.same", bearer=bearer2)
    assert r2.status_code == 200, r2.text
    assert r2.json()["anon_id"] == user_id  # same account (keyed on apple_sub)

    assert await _usage_today(db_sessionmaker, user_id) == 12  # 7 + 5, summed


async def test_sign_out_back_to_same_anon_keeps_its_counter_no_reset(
    client, keypair, db_sessionmaker
):
    """Sign-out on a device returns it to the SAME anon subject (its App Attest
    key binding never changes). If the merge dropped the anon's rows, that
    return trip would hand out a fresh daily bucket — the counter must survive."""
    anon_id, bearer = await _make_anon(db_sessionmaker)
    await _seed_usage(db_sessionmaker, anon_id, 7)

    r = await _call_apple(client, keypair, sub="apple.sub.keep", bearer=bearer)
    assert r.status_code == 200, r.text

    # Back as the anon after sign-out: today's count is still 7, not a reset.
    assert await _usage_today(db_sessionmaker, anon_id) == 7


async def test_repeat_call_with_same_anon_is_idempotent_no_double_count(
    client, keypair, db_sessionmaker
):
    anon_id, bearer = await _make_anon(db_sessionmaker)
    await _seed_usage(db_sessionmaker, anon_id, 9)

    r1 = await _call_apple(client, keypair, sub="apple.sub.idem", bearer=bearer)
    assert r1.status_code == 200, r1.text
    user_id = r1.json()["anon_id"]
    assert await _usage_today(db_sessionmaker, user_id) == 9

    # Same anon bearer again → the upgrade guard makes it a no-op, no double count.
    r2 = await _call_apple(client, keypair, sub="apple.sub.idem", bearer=bearer)
    assert r2.status_code == 200, r2.text
    assert await _usage_today(db_sessionmaker, user_id) == 9


# ── Guards: anon already claimed, bad token, missing bearer, unconfigured ────


async def test_anon_already_upgraded_to_another_account_is_rejected_409(
    client, keypair, db_sessionmaker
):
    """An anon already folded into account A cannot then be folded into a new
    account B — and B must not be created (the whole call rolls back)."""
    anon_id, bearer = await _make_anon(db_sessionmaker)
    r1 = await _call_apple(client, keypair, sub="apple.sub.A", bearer=bearer)
    assert r1.status_code == 200, r1.text

    r2 = await _call_apple(client, keypair, sub="apple.sub.B", bearer=bearer)
    assert r2.status_code == 409
    assert await _get_user(db_sessionmaker, "apple.sub.B") is None  # rolled back


async def test_invalid_identity_token_is_rejected_401_and_creates_no_account(
    client, keypair, db_sessionmaker
):
    """A nonce that does not match this attempt fails verification → 401, and no
    account is created (a forged/replayed token cannot mint an account)."""
    _, bearer = await _make_anon(db_sessionmaker)
    resp = await _call_apple(
        client, keypair, sub="apple.sub.bad", bearer=bearer, raw_nonce="not-the-nonce"
    )
    assert resp.status_code == 401
    assert await _get_user(db_sessionmaker, "apple.sub.bad") is None


async def test_sign_in_without_a_bearer_creates_account_without_merge(
    client, keypair, db_sessionmaker
):
    """No anon bearer → nothing to fold, but the account is still created and the
    server still issues tokens whose subject is users.id."""
    resp = await _call_apple(client, keypair, sub="apple.sub.nobearer")
    assert resp.status_code == 200, resp.text
    user = await _get_user(db_sessionmaker, "apple.sub.nobearer")
    assert user is not None
    assert resp.json()["anon_id"] == str(user.id)
    assert await _usage_today(db_sessionmaker, str(user.id)) is None


async def test_returns_503_when_sign_in_with_apple_is_unconfigured(
    db_sessionmaker, keypair
):
    limiter.reset()
    app = _make_app(db_sessionmaker, keypair.public_key(), apple_configured=False)
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        resp = await _call_apple(c, keypair, sub="apple.sub.x")
    assert resp.status_code == 503
