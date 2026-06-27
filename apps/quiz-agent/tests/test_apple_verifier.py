"""Tests for the Apple identity-token verifier (issue #61, task 61.2).

Real Apple ``id_token``s are signed by Apple's private keys we cannot hold, so
these mint synthetic tokens with a throwaway RSA keypair and stub Apple's JWKS
endpoint with an ``httpx.MockTransport`` — the same "swap the trust root for a
test one" technique ``test_app_attest`` uses. No network, no DB.

What is pinned is the security contract, not round-tripping: a tampered
signature, the wrong audience/issuer, an expired token, an unknown signing key,
and — the footgun decision F6 calls out — a ``nonce`` claim in the raw or hex
form rather than ``base64url-nopad(sha256(raw_nonce))`` must each be rejected, so
a forged, stale, or replayed token can never stand in for a real Apple sign-in.
"""

from __future__ import annotations

import base64
import hashlib
import json
from datetime import datetime, timedelta, timezone

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from jwt.algorithms import RSAAlgorithm

from app.auth.apple import (
    AppleIdentityVerifier,
    AppleVerificationError,
    expected_nonce_claim,
)


AUDIENCE = "com.missinghue.hangs"  # native SIWA → aud is the app bundle id
ISSUER = "https://appleid.apple.com"
JWKS_URL = "https://appleid.apple.com/auth/keys"
KID = "test-kid"
RAW_NONCE = "raw-nonce-the-client-generated-0123456789ab"


# ── Synthetic key + token + JWKS builders ────────────────────────────────────


@pytest.fixture(scope="module")
def keypair() -> rsa.RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _jwks(public_key, *, kid: str = KID) -> dict:
    jwk = json.loads(RSAAlgorithm.to_jwk(public_key))
    jwk.update({"kid": kid, "alg": "RS256", "use": "sig"})
    return {"keys": [jwk]}


def _client(jwks: dict, *, calls: list | None = None) -> httpx.AsyncClient:
    def handler(request: httpx.Request) -> httpx.Response:
        if calls is not None:
            calls.append(str(request.url))
        return httpx.Response(200, json=jwks)

    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


def _claims(**overrides) -> dict:
    now = datetime.now(timezone.utc)
    base = {
        "iss": ISSUER,
        "aud": AUDIENCE,
        "sub": "001999.applesubjectid.0001",
        "iat": now,
        "exp": now + timedelta(minutes=10),
        "email": "user@privaterelay.appleid.com",
        "nonce": expected_nonce_claim(RAW_NONCE),
    }
    base.update(overrides)
    return base


def _token(key: rsa.RSAPrivateKey, claims: dict, *, kid: str = KID) -> str:
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": kid})


def _verifier(public_key, **kwargs) -> AppleIdentityVerifier:
    return AppleIdentityVerifier(
        audience=AUDIENCE, http_client=_client(_jwks(public_key), **kwargs)
    )


# ── F6 nonce encoding pinned independently ───────────────────────────────────


def test_expected_nonce_claim_is_base64url_nopad_sha256():
    """F6 is an exact encoding, not 'any hash of the nonce'. Pin it directly so a
    later refactor can't silently switch to hex or raw and pass the suite."""
    want = (
        base64.urlsafe_b64encode(hashlib.sha256(b"abc").digest()).rstrip(b"=").decode()
    )
    got = expected_nonce_claim("abc")
    assert got == want
    assert "=" not in got  # no padding
    assert got != hashlib.sha256(b"abc").hexdigest()  # NOT hex
    assert got != "abc"  # NOT the raw nonce
    assert expected_nonce_claim("abc") == expected_nonce_claim(b"abc")  # str≡bytes


# ── Happy path ───────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_valid_token_returns_claims(keypair):
    """A correctly signed, in-audience, unexpired token with the F6 nonce returns
    the claims we build accounts from (sub is the durable account anchor)."""
    verifier = _verifier(keypair.public_key())
    claims = await verifier.verify(_token(keypair, _claims()), raw_nonce=RAW_NONCE)
    assert claims["sub"] == "001999.applesubjectid.0001"
    assert claims["email"] == "user@privaterelay.appleid.com"


# ── Signature / issuer / audience / expiry ───────────────────────────────────


@pytest.mark.asyncio
async def test_tampered_signature_is_rejected(keypair):
    """Flipping a signature byte must fail — a client cannot rewrite its claims."""
    verifier = _verifier(keypair.public_key())
    token = _token(keypair, _claims())
    header, payload, sig = token.split(".")
    forged = ".".join(
        [header, payload, sig[:-2] + ("AA" if sig[-2:] != "AA" else "BB")]
    )
    with pytest.raises(AppleVerificationError):
        await verifier.verify(forged, raw_nonce=RAW_NONCE)


@pytest.mark.asyncio
async def test_token_signed_by_a_foreign_key_is_rejected(keypair):
    """A token whose advertised kid resolves to Apple's JWKS but is actually
    signed by a different key must fail signature verification."""
    impostor = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    verifier = _verifier(keypair.public_key())  # JWKS publishes keypair's key
    token = _token(impostor, _claims())  # but the token is signed by impostor
    with pytest.raises(AppleVerificationError):
        await verifier.verify(token, raw_nonce=RAW_NONCE)


@pytest.mark.asyncio
async def test_wrong_audience_is_rejected(keypair):
    """A token minted for another app's bundle id must not unlock our accounts."""
    verifier = _verifier(keypair.public_key())
    token = _token(keypair, _claims(aud="com.someone.else"))
    with pytest.raises(AppleVerificationError):
        await verifier.verify(token, raw_nonce=RAW_NONCE)


@pytest.mark.asyncio
async def test_wrong_issuer_is_rejected(keypair):
    """Only Apple may issue these tokens."""
    verifier = _verifier(keypair.public_key())
    token = _token(keypair, _claims(iss="https://evil.example.com"))
    with pytest.raises(AppleVerificationError):
        await verifier.verify(token, raw_nonce=RAW_NONCE)


@pytest.mark.asyncio
async def test_expired_token_is_rejected(keypair):
    """Apple id_tokens live 5–10 min; a stale one must not verify."""
    verifier = _verifier(keypair.public_key())
    past = datetime.now(timezone.utc) - timedelta(hours=2)
    token = _token(keypair, _claims(iat=past, exp=past + timedelta(minutes=10)))
    with pytest.raises(AppleVerificationError):
        await verifier.verify(token, raw_nonce=RAW_NONCE)


# ── Nonce (F6) — the most common bug in this flow ────────────────────────────


@pytest.mark.asyncio
async def test_nonce_in_raw_form_is_rejected(keypair):
    """The 'not raw' half of F6: a token echoing the raw nonce (the naive mistake)
    must NOT pass — only base64url-nopad(sha256(nonce)) does."""
    verifier = _verifier(keypair.public_key())
    token = _token(keypair, _claims(nonce=RAW_NONCE))
    with pytest.raises(AppleVerificationError):
        await verifier.verify(token, raw_nonce=RAW_NONCE)


@pytest.mark.asyncio
async def test_nonce_in_hex_form_is_rejected(keypair):
    """The 'not hex' half of F6: a hex sha256 digest must NOT pass either."""
    verifier = _verifier(keypair.public_key())
    hex_nonce = hashlib.sha256(RAW_NONCE.encode()).hexdigest()
    token = _token(keypair, _claims(nonce=hex_nonce))
    with pytest.raises(AppleVerificationError):
        await verifier.verify(token, raw_nonce=RAW_NONCE)


@pytest.mark.asyncio
async def test_missing_nonce_claim_is_rejected(keypair):
    """A token with no nonce cannot be tied to this sign-in attempt → reject."""
    claims = _claims()
    claims.pop("nonce")
    verifier = _verifier(keypair.public_key())
    token = _token(keypair, claims)
    with pytest.raises(AppleVerificationError):
        await verifier.verify(token, raw_nonce=RAW_NONCE)


@pytest.mark.asyncio
async def test_nonce_for_a_different_attempt_is_rejected(keypair):
    """A valid token whose nonce matches a DIFFERENT raw nonce (a captured token
    replayed into our attempt) must fail."""
    verifier = _verifier(keypair.public_key())
    token = _token(keypair, _claims(nonce=expected_nonce_claim("some-other-nonce")))
    with pytest.raises(AppleVerificationError):
        await verifier.verify(token, raw_nonce=RAW_NONCE)


# ── JWKS resolution: unknown kid, rotation refresh, caching ──────────────────


@pytest.mark.asyncio
async def test_unknown_kid_is_rejected(keypair):
    """A token whose kid is in no published Apple key must fail (and not crash)."""
    verifier = _verifier(keypair.public_key())
    token = _token(keypair, _claims(), kid="kid-apple-never-published")
    with pytest.raises(AppleVerificationError):
        await verifier.verify(token, raw_nonce=RAW_NONCE)


@pytest.mark.asyncio
async def test_unknown_kid_triggers_one_jwks_refresh_then_resolves(keypair):
    """Apple rotates keys: a kid missing from the cached set must force exactly one
    refresh that can then resolve it (otherwise valid logins break on rotation)."""
    calls: list[str] = []
    # First fetch returns a stale keyset (wrong kid); second returns the real key.
    stale = _jwks(
        rsa.generate_private_key(public_exponent=65537, key_size=2048).public_key(),
        kid="stale-kid",
    )
    fresh = _jwks(keypair.public_key(), kid=KID)
    responses = [stale, fresh]

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(str(request.url))
        return httpx.Response(200, json=responses[min(len(calls) - 1, 1)])

    verifier = AppleIdentityVerifier(
        audience=AUDIENCE,
        http_client=httpx.AsyncClient(transport=httpx.MockTransport(handler)),
    )
    claims = await verifier.verify(_token(keypair, _claims()), raw_nonce=RAW_NONCE)
    assert claims["sub"] == "001999.applesubjectid.0001"
    assert len(calls) == 2  # stale hit forced one (and only one) refresh


@pytest.mark.asyncio
async def test_jwks_is_cached_across_verifications(keypair):
    """The 24h cache must serve a second verify without re-fetching — Apple's
    JWKS rarely rotates and a fetch-per-login is needless load."""
    calls: list[str] = []
    verifier = _verifier(keypair.public_key(), calls=calls)
    await verifier.verify(_token(keypair, _claims()), raw_nonce=RAW_NONCE)
    await verifier.verify(_token(keypair, _claims()), raw_nonce=RAW_NONCE)
    assert len(calls) == 1


# ── Construction guard ───────────────────────────────────────────────────────


def test_verifier_requires_an_audience():
    """No bundle id → fail loud at construction, never verify against an empty
    audience (which python-jwt would treat as 'skip the aud check')."""
    with pytest.raises(RuntimeError):
        AppleIdentityVerifier(audience="")
