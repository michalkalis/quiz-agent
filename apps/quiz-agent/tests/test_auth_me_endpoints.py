"""Integration tests for the GDPR account endpoints — ``DELETE /auth/me`` and
``GET /auth/me/export`` (issue #61, task 61.5).

These pin the contract a deletion/export must honour:

- DELETE erases *all* of the account's local data in one transaction — the
  ``users`` row, its ``daily_usage`` and its ``refresh_tokens`` (the latter has no
  cascade after migration 0004, so it must be removed explicitly) — and de-links
  the merged anonymous trail, then revokes the grant at Apple with the **decrypted**
  refresh token;
- the revoke is **best-effort** (F4): an Apple failure, or no stored refresh token
  at all, still leaves the account deleted and returns success — Apple availability
  never blocks a GDPR erasure;
- EXPORT returns the account's own data and **never leaks** the encrypted Apple
  refresh token or any secret;
- both endpoints act only for a real account: an anonymous/legacy or
  unauthenticated subject (not a ``users.id``) is rejected.

Apple's ``/auth/revoke`` is mocked with an ``httpx.MockTransport`` that records the
call; the auth tables use the real test Postgres via ``db_sessionmaker``.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs

import httpx
import pytest
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from sqlalchemy import select

from app.api.routes import auth as auth_routes
from app.auth.apple_oauth import AppleOAuthClient
from app.auth.apple_secrets import AppleTokenCipher
from app.auth.refresh import RefreshTokenStore
from app.auth.tokens import TokenService
from app.db.models import AnonymousIdentity, DailyUsage, RefreshToken, User
from app.rate_limit import limiter

pytestmark = pytest.mark.asyncio

AUDIENCE = "com.missinghue.hangs"  # native SIWA → client_id is the app bundle id
TEAM_ID = "KAGWHPZZFQ"
KEY_ID = "ABC123KEYID"
ENC_KEY = Fernet.generate_key()
APPLE_REFRESH = "apple-refresh-token-xyz"

_SECRET = "t" * 64
_JWT_ISSUER = "quiz-agent"
_JWT_AUDIENCE = "quiz-agent-clients"
_TTL = 900


def _today():
    return datetime.now(timezone.utc).date()


def _token_service() -> TokenService:
    return TokenService(
        secret=_SECRET,
        issuer=_JWT_ISSUER,
        audience=_JWT_AUDIENCE,
        access_ttl_seconds=_TTL,
    )


def _es256_pem() -> str:
    key = ec.generate_private_key(ec.SECP256R1())
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()


_P8 = _es256_pem()


# ── Apple /auth/revoke stub that records each call ───────────────────────────


class RevokeRecorder:
    """Mock Apple's ``/auth/revoke`` (and a benign token endpoint). Records every
    revoke's decoded form body so a test can assert the token we sent; ``fail``
    makes Apple answer 400, to exercise the F4 best-effort path."""

    def __init__(self, *, fail: bool = False) -> None:
        self.calls: list[dict] = []
        self.fail = fail

    def _handler(self, req: httpx.Request) -> httpx.Response:
        if req.url.path.endswith("/auth/revoke"):
            self.calls.append(
                {k: v[0] for k, v in parse_qs(req.content.decode()).items()}
            )
            if self.fail:
                return httpx.Response(400, json={"error": "invalid_client"})
            return httpx.Response(200)  # Apple: empty 200 body on success
        return httpx.Response(200, json={"access_token": "a", "token_type": "Bearer"})

    def client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=httpx.MockTransport(self._handler))


def _make_app(
    db_sessionmaker,
    *,
    recorder: RevokeRecorder | None = None,
    apple_configured: bool = True,
) -> FastAPI:
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(auth_routes.router, prefix="/api/v1")
    app.state.token_service = _token_service()
    app.state.refresh_store = RefreshTokenStore(
        db_sessionmaker, ttl_days=30, family_max_days=60
    )
    app.state.auth_sessionmaker = db_sessionmaker
    app.state.apple_verifier = None  # delete/export never verify an id_token
    if apple_configured:
        app.state.apple_oauth_client = AppleOAuthClient(
            team_id=TEAM_ID,
            client_id=AUDIENCE,
            key_id=KEY_ID,
            private_key=_P8,
            http_client=(recorder or RevokeRecorder()).client(),
        )
        app.state.apple_token_cipher = AppleTokenCipher(ENC_KEY)
    else:
        app.state.apple_oauth_client = None
        app.state.apple_token_cipher = None
    return app


def _asgi(app) -> AsyncClient:
    return AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


def _auth(bearer: str | None) -> dict:
    return {"Authorization": f"Bearer {bearer}"} if bearer else {}


# ── DB helpers ───────────────────────────────────────────────────────────────


async def _make_account(
    db,
    *,
    apple_sub: str = "apple.sub.acct",
    email: str | None = "user@privaterelay.appleid.com",
    full_name: str | None = "Jan Novak",
    refresh_plaintext: str | None = APPLE_REFRESH,
) -> tuple[str, str]:
    """Insert a ``users`` row (Apple refresh token encrypted, like real sign-in) and
    return (user_id, an account bearer whose JWT sub is that user_id)."""
    user_id = uuid.uuid4()
    encrypted = (
        AppleTokenCipher(ENC_KEY).encrypt(refresh_plaintext)
        if refresh_plaintext is not None
        else None
    )
    async with db() as s:
        s.add(
            User(
                id=user_id,
                apple_sub=apple_sub,
                email=email,
                full_name=full_name,
                apple_refresh_token_encrypted=encrypted,
            )
        )
        await s.commit()
    return str(user_id), _token_service().create_access_token(str(user_id))


async def _seed_usage(
    db, subject_id: str, count: int, *, day=None, premium: bool = False
) -> None:
    async with db() as s:
        s.add(
            DailyUsage(
                subject_id=subject_id,
                usage_date=day or _today(),
                questions_count=count,
                is_premium=premium,
            )
        )
        await s.commit()


async def _seed_refresh(db, subject_id: str) -> None:
    async with db() as s:
        s.add(
            RefreshToken(
                token_hash=f"hash-{uuid.uuid4()}",
                family_id=uuid.uuid4(),
                anon_id=subject_id,
                expires_at=datetime.now(timezone.utc) + timedelta(days=30),
            )
        )
        await s.commit()


async def _seed_anon_upgraded(db, user_id: str) -> str:
    anon_id = str(uuid.uuid4())
    async with db() as s:
        s.add(AnonymousIdentity(anon_id=anon_id, upgraded_to_user_id=user_id))
        await s.commit()
    return anon_id


async def _user_exists(db, user_id: str) -> bool:
    async with db() as s:
        row = (
            await s.execute(select(User).where(User.id == uuid.UUID(user_id)))
        ).scalar_one_or_none()
    return row is not None


async def _rows(db, model, *where) -> list:
    async with db() as s:
        return list((await s.execute(select(model).where(*where))).scalars().all())


async def _anon(db, anon_id: str) -> AnonymousIdentity | None:
    async with db() as s:
        return (
            await s.execute(
                select(AnonymousIdentity).where(AnonymousIdentity.anon_id == anon_id)
            )
        ).scalar_one_or_none()


# ── DELETE: full erasure + revoke with the decrypted token ───────────────────


async def test_delete_erases_all_data_and_revokes_with_decrypted_token(
    db_sessionmaker,
):
    recorder = RevokeRecorder()
    app = _make_app(db_sessionmaker, recorder=recorder)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="apple.sub.del")
    await _seed_usage(db_sessionmaker, user_id, 4)
    await _seed_refresh(db_sessionmaker, user_id)
    anon_id = await _seed_anon_upgraded(db_sessionmaker, user_id)

    async with _asgi(app) as c:
        resp = await c.delete("/api/v1/auth/me", headers=_auth(bearer))

    assert resp.status_code == 204, resp.text
    assert resp.content == b""

    # Local data is gone …
    assert not await _user_exists(db_sessionmaker, user_id)
    assert (
        await _rows(db_sessionmaker, DailyUsage, DailyUsage.subject_id == user_id) == []
    )
    assert (
        await _rows(db_sessionmaker, RefreshToken, RefreshToken.anon_id == user_id)
        == []
    )
    # … and the merged anon trail is de-linked (row kept, pointer nulled).
    anon = await _anon(db_sessionmaker, anon_id)
    assert anon is not None
    assert anon.upgraded_to_user_id is None

    # Apple was revoked with the DECRYPTED refresh token (proves we decrypted).
    assert len(recorder.calls) == 1
    call = recorder.calls[0]
    assert call["token"] == APPLE_REFRESH
    assert call["token_type_hint"] == "refresh_token"
    assert call["client_id"] == AUDIENCE
    assert call["client_secret"]  # the signed ES256 client_secret was sent


async def test_delete_carries_todays_count_back_to_the_linked_anon(db_sessionmaker):
    """Anti-abuse: the device's App Attest key returns it to its anon subject
    right after the delete — if today's counter died with the account, every
    delete would be a free daily-limit reset. Today's count must land on the
    linked anon (without premium: the entitlement dies with the account)."""
    app = _make_app(db_sessionmaker)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="apple.sub.carry")
    await _seed_usage(db_sessionmaker, user_id, 11, premium=True)
    anon_id = await _seed_anon_upgraded(db_sessionmaker, user_id)

    async with _asgi(app) as c:
        resp = await c.delete("/api/v1/auth/me", headers=_auth(bearer))
    assert resp.status_code == 204, resp.text

    rows = await _rows(db_sessionmaker, DailyUsage, DailyUsage.subject_id == anon_id)
    assert len(rows) == 1
    assert rows[0].usage_date == _today()
    assert rows[0].questions_count == 11
    assert rows[0].is_premium is False  # premium is NOT carried over


async def test_delete_todays_carry_takes_the_greater_of_both_counters(
    db_sessionmaker,
):
    """If the anon already holds a (frozen, pre-merge) count for today, the carry
    uses GREATEST — it can only tighten the limit, never loosen or double it."""
    app = _make_app(db_sessionmaker)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="apple.sub.max")
    await _seed_usage(db_sessionmaker, user_id, 5)
    anon_id = await _seed_anon_upgraded(db_sessionmaker, user_id)
    await _seed_usage(db_sessionmaker, anon_id, 9)  # anon's frozen count is higher

    async with _asgi(app) as c:
        resp = await c.delete("/api/v1/auth/me", headers=_auth(bearer))
    assert resp.status_code == 204, resp.text

    rows = await _rows(db_sessionmaker, DailyUsage, DailyUsage.subject_id == anon_id)
    assert [r.questions_count for r in rows] == [9]  # max(9, 5), not 14


async def test_delete_succeeds_even_when_apple_revoke_fails(db_sessionmaker):
    """F4: an Apple-side revoke failure must NOT reverse or block the local delete."""
    recorder = RevokeRecorder(fail=True)
    app = _make_app(db_sessionmaker, recorder=recorder)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="apple.sub.f4")

    async with _asgi(app) as c:
        resp = await c.delete("/api/v1/auth/me", headers=_auth(bearer))

    assert resp.status_code == 204, resp.text
    assert not await _user_exists(db_sessionmaker, user_id)
    assert len(recorder.calls) == 1  # we did attempt the revoke


async def test_delete_with_no_stored_refresh_token_skips_revoke(db_sessionmaker):
    """No Apple refresh token stored → nothing to revoke (no-token path); the
    account is still deleted and success returned."""
    recorder = RevokeRecorder()
    app = _make_app(db_sessionmaker, recorder=recorder)
    user_id, bearer = await _make_account(
        db_sessionmaker, apple_sub="apple.sub.notoken", refresh_plaintext=None
    )

    async with _asgi(app) as c:
        resp = await c.delete("/api/v1/auth/me", headers=_auth(bearer))

    assert resp.status_code == 204, resp.text
    assert not await _user_exists(db_sessionmaker, user_id)
    assert recorder.calls == []  # revoke never attempted (no token)


async def test_delete_is_idempotent_second_call_is_404(db_sessionmaker):
    app = _make_app(db_sessionmaker)
    _, bearer = await _make_account(db_sessionmaker, apple_sub="apple.sub.idem")

    async with _asgi(app) as c:
        first = await c.delete("/api/v1/auth/me", headers=_auth(bearer))
        second = await c.delete("/api/v1/auth/me", headers=_auth(bearer))

    assert first.status_code == 204, first.text
    assert second.status_code == 404  # account already gone


# ── EXPORT: shape + no secret leak ───────────────────────────────────────────


async def test_export_returns_account_data_and_leaks_no_secret(db_sessionmaker):
    app = _make_app(db_sessionmaker)
    user_id, bearer = await _make_account(
        db_sessionmaker,
        apple_sub="apple.sub.exp",
        email="jan@privaterelay.appleid.com",
        full_name="Jan Novak",
    )
    yesterday = _today() - timedelta(days=1)
    await _seed_usage(db_sessionmaker, user_id, 2, day=yesterday)
    await _seed_usage(db_sessionmaker, user_id, 4, premium=True)

    async with _asgi(app) as c:
        resp = await c.get("/api/v1/auth/me/export", headers=_auth(bearer))

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["apple_sub"] == "apple.sub.exp"
    assert body["email"] == "jan@privaterelay.appleid.com"
    assert body["full_name"] == "Jan Novak"
    assert body["created_at"]
    assert body["is_premium"] is True  # today's row is premium

    # Full history, oldest first.
    assert [(r["questions_count"], r["is_premium"]) for r in body["usage"]] == [
        (2, False),
        (4, True),
    ]

    # No secret may appear anywhere in the payload.
    raw = resp.text
    assert APPLE_REFRESH not in raw
    assert "refresh_token" not in raw
    user_rows = await _rows(db_sessionmaker, User, User.id == uuid.UUID(user_id))
    ciphertext = user_rows[0].apple_refresh_token_encrypted
    assert ciphertext is not None
    assert ciphertext.decode() not in raw


# ── Authority rule: only a real account may delete/export ────────────────────


async def test_endpoints_reject_unauthenticated_caller(db_sessionmaker):
    app = _make_app(db_sessionmaker)
    async with _asgi(app) as c:
        deleted = await c.delete("/api/v1/auth/me")
        exported = await c.get("/api/v1/auth/me/export")
    assert deleted.status_code == 401
    assert exported.status_code == 401


async def test_endpoints_reject_authenticated_non_account_subject(db_sessionmaker):
    """A valid bearer whose subject is an anon id (or a legacy ``dev_…`` id), not a
    ``users.id``, has no account to act on → 404, and no revoke is attempted."""
    recorder = RevokeRecorder()
    app = _make_app(db_sessionmaker, recorder=recorder)
    anon_bearer = _token_service().create_access_token(str(uuid.uuid4()))
    legacy_bearer = _token_service().create_access_token("dev_legacy_device_42")

    async with _asgi(app) as c:
        for bearer in (anon_bearer, legacy_bearer):
            deleted = await c.delete("/api/v1/auth/me", headers=_auth(bearer))
            exported = await c.get("/api/v1/auth/me/export", headers=_auth(bearer))
            assert deleted.status_code == 404, deleted.text
            assert exported.status_code == 404, exported.text
    assert recorder.calls == []  # nothing deleted, nothing revoked


async def test_delete_returns_503_when_auth_db_unavailable(db_sessionmaker):
    app = _make_app(db_sessionmaker)
    app.state.auth_sessionmaker = None  # auth/DB disabled
    bearer = _token_service().create_access_token(str(uuid.uuid4()))
    async with _asgi(app) as c:
        resp = await c.delete("/api/v1/auth/me", headers=_auth(bearer))
    assert resp.status_code == 503
