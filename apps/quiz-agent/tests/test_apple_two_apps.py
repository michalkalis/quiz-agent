"""Sign in with Apple from two apps: App Store + Trubbo Beta (#234).

Apple binds an authorization code, and the refresh token it yields, to the
client (app bundle id) that requested it. With a second app signing in:

- an id_token for either configured app must be accepted, and only those;
- the code exchange must authenticate as the app the token was issued to,
  otherwise Apple answers `invalid_client` and beta sign-in fails;
- the account-deletion revoke must authenticate as that same app, otherwise
  Apple refuses it and the GDPR revoke silently does nothing. So the issuing
  client id is stored next to the refresh token;
- a row stored before #234 (no client id) revokes as the primary app, which is
  the only app that could have issued it.
"""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs

import httpx
import jwt
import pytest
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
from app.auth.apple import (
    AppleIdentityVerifier,
    AppleVerificationError,
    expected_nonce_claim,
)
from app.auth.apple_oauth import AppleOAuthClient, AppleOAuthError
from app.auth.apple_secrets import AppleTokenCipher
from app.auth.refresh import RefreshTokenStore
from app.auth.tokens import TokenService
from app.config import Settings
from app.db.models import User
from app.rate_limit import limiter

LIVE = "com.missinghue.hangs"
BETA = "com.missinghue.hangs.beta"
TEAM_ID = "KAGWHPZZFQ"
KEY_ID = "ABC123KEYID"
KID = "test-kid"
RAW_NONCE = "raw-nonce-the-client-generated-0123456789ab"
ENC_KEY = Fernet.generate_key()
APPLE_REFRESH = "apple-refresh-token-beta"


def _p8() -> str:
    return (
        ec.generate_private_key(ec.SECP256R1())
        .private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
        .decode()
    )


_P8 = _p8()


@pytest.fixture(scope="module")
def keypair() -> rsa.RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _jwks_client(public_key) -> httpx.AsyncClient:
    jwk = json.loads(RSAAlgorithm.to_jwk(public_key))
    jwk.update({"kid": KID, "alg": "RS256", "use": "sig"})
    body = {"keys": [jwk]}
    return httpx.AsyncClient(
        transport=httpx.MockTransport(lambda req: httpx.Response(200, json=body))
    )


def _id_token(key, *, aud: str, sub: str = "001999.beta.sub") -> str:
    now = datetime.now(timezone.utc)
    claims = {
        "iss": "https://appleid.apple.com",
        "aud": aud,
        "sub": sub,
        "iat": now,
        "exp": now + timedelta(minutes=10),
        "nonce": expected_nonce_claim(RAW_NONCE),
    }
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": KID})


class AppleRecorder:
    """Mock Apple's /auth/token and /auth/revoke; records each decoded form."""

    def __init__(self) -> None:
        self.token_calls: list[dict] = []
        self.revoke_calls: list[dict] = []

    def _handler(self, req: httpx.Request) -> httpx.Response:
        form = {k: v[0] for k, v in parse_qs(req.content.decode()).items()}
        if req.url.path.endswith("/auth/revoke"):
            self.revoke_calls.append(form)
            return httpx.Response(200)
        self.token_calls.append(form)
        return httpx.Response(
            200, json={"access_token": "a", "refresh_token": APPLE_REFRESH}
        )

    def client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=httpx.MockTransport(self._handler))


def _oauth(recorder: AppleRecorder, client_ids=(LIVE, BETA)) -> AppleOAuthClient:
    return AppleOAuthClient(
        team_id=TEAM_ID,
        client_id=client_ids,
        key_id=KEY_ID,
        private_key=_P8,
        http_client=recorder.client(),
    )


def _secret_sub(form: dict) -> str:
    return jwt.decode(form["client_secret"], options={"verify_signature": False})["sub"]


# ── id_token audience ───────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_id_token_from_either_configured_app_verifies(keypair):
    verifier = AppleIdentityVerifier(
        audience=(LIVE, BETA), http_client=_jwks_client(keypair.public_key())
    )
    for aud in (LIVE, BETA):
        claims = await verifier.verify(_id_token(keypair, aud=aud), raw_nonce=RAW_NONCE)
        assert claims["aud"] == aud  # the route reads the issuing app from here


@pytest.mark.asyncio
async def test_two_apps_do_not_widen_the_audience_to_any_app(keypair):
    verifier = AppleIdentityVerifier(
        audience=(LIVE, BETA), http_client=_jwks_client(keypair.public_key())
    )
    with pytest.raises(AppleVerificationError):
        await verifier.verify(
            _id_token(keypair, aud="com.someone.else"), raw_nonce=RAW_NONCE
        )


@pytest.mark.asyncio
async def test_single_client_config_rejects_the_beta_app_as_before(keypair):
    verifier = AppleIdentityVerifier(
        audience=LIVE, http_client=_jwks_client(keypair.public_key())
    )
    with pytest.raises(AppleVerificationError):
        await verifier.verify(_id_token(keypair, aud=BETA), raw_nonce=RAW_NONCE)


def test_client_id_env_is_a_list_with_the_store_app_first(monkeypatch):
    monkeypatch.setenv("APPLE_SIGNIN_CLIENT_ID", f"{LIVE}, {BETA}")
    monkeypatch.setenv("APP_ATTEST_APP_ID", f"T.{LIVE},T.{BETA}")
    settings = Settings()
    assert settings.apple_signin_client_ids == (LIVE, BETA)
    assert settings.app_attest_app_ids == (f"T.{LIVE}", f"T.{BETA}")
    monkeypatch.setenv("APPLE_SIGNIN_CLIENT_ID", LIVE)
    assert Settings().apple_signin_client_ids == (LIVE,)


# ── OAuth client: authenticate as the issuing app ───────────────────────────


@pytest.mark.asyncio
async def test_code_exchange_authenticates_as_the_app_that_got_the_code():
    recorder = AppleRecorder()
    await _oauth(recorder).exchange_authorization_code("code", client_id=BETA)
    form = recorder.token_calls[0]
    assert form["client_id"] == BETA
    assert _secret_sub(form) == BETA


@pytest.mark.asyncio
async def test_code_exchange_refuses_an_unconfigured_client():
    recorder = AppleRecorder()
    with pytest.raises(AppleOAuthError):
        await _oauth(recorder, client_ids=(LIVE,)).exchange_authorization_code(
            "code", client_id=BETA
        )
    assert recorder.token_calls == []


@pytest.mark.asyncio
async def test_revoke_without_a_stored_client_uses_the_primary_app():
    # Every refresh token stored before #234 came from the App Store app.
    recorder = AppleRecorder()
    await _oauth(recorder).revoke("old-token")
    assert recorder.revoke_calls[0]["client_id"] == LIVE
    assert _secret_sub(recorder.revoke_calls[0]) == LIVE


# ── End to end: beta sign-in stores its client, deletion revokes with it ────


def _make_app(db_sessionmaker, public_key, recorder: AppleRecorder) -> FastAPI:
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(auth_routes.router, prefix="/api/v1")
    app.state.token_service = TokenService(
        secret="t" * 64, issuer="quiz-agent", audience="quiz-agent-clients"
    )
    app.state.refresh_store = RefreshTokenStore(
        db_sessionmaker, ttl_days=30, family_max_days=60
    )
    app.state.auth_sessionmaker = db_sessionmaker
    app.state.apple_verifier = AppleIdentityVerifier(
        audience=(LIVE, BETA), http_client=_jwks_client(public_key)
    )
    app.state.apple_oauth_client = _oauth(recorder)
    app.state.apple_token_cipher = AppleTokenCipher(ENC_KEY)
    return app


@pytest.mark.asyncio
async def test_beta_sign_in_then_account_deletion_revokes_as_the_beta_app(
    db_sessionmaker, keypair
):
    recorder = AppleRecorder()
    app = _make_app(db_sessionmaker, keypair.public_key(), recorder)
    sub = f"apple.beta.{uuid.uuid4()}"
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        resp = await c.post(
            "/api/v1/auth/apple",
            json={
                "identity_token": _id_token(keypair, aud=BETA, sub=sub),
                "authorization_code": "beta-code",
                "raw_nonce": RAW_NONCE,
            },
        )
        assert resp.status_code == 200, resp.text
        assert recorder.token_calls[0]["client_id"] == BETA

        async with db_sessionmaker() as s:
            user = (
                await s.execute(select(User).where(User.apple_sub == sub))
            ).scalar_one()
        assert user.apple_refresh_token_client_id == BETA

        resp = await c.delete(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {resp.json()['access_token']}"},
        )
        assert resp.status_code == 204, resp.text

    assert len(recorder.revoke_calls) == 1
    revoke = recorder.revoke_calls[0]
    assert revoke["token"] == APPLE_REFRESH
    assert revoke["client_id"] == BETA
    assert _secret_sub(revoke) == BETA
