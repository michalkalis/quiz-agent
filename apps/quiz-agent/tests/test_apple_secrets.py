"""Tests for the Apple client_secret generator and refresh-token cipher
(issue #61, task 61.3).

The client_secret is the credential Apple's token/revoke endpoints authenticate
us with, so the test verifies its *real signature* with the public half of a
throwaway EC key (not just that a string came back) and pins the claims Apple
requires plus the 6-month lifetime cap (F10). The cipher is what keeps Apple's
refresh token out of the clear at rest (F1/F2): the test asserts a round-trip,
that the ciphertext is not the plaintext, that tampering is detected, and that a
missing key fails loud rather than silently storing a secret unencrypted.
"""

from __future__ import annotations

from datetime import datetime, timezone

import jwt
import pytest
from cryptography.fernet import Fernet, InvalidToken
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.auth.apple_secrets import (
    AppleTokenCipher,
    generate_client_secret,
    _MAX_CLIENT_SECRET_TTL_SECONDS,
)

TEAM_ID = "KAGWHPZZFQ"
CLIENT_ID = "com.missinghue.hangs"
KEY_ID = "ABC123DEFG"
APPLE_AUDIENCE = "https://appleid.apple.com"


@pytest.fixture(scope="module")
def p8_keypair():
    """An EC P-256 key standing in for the Sign in with Apple .p8."""
    private = ec.generate_private_key(ec.SECP256R1())
    pem = private.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    return pem, private.public_key()


def _generate(p8_pem: str, **kwargs) -> str:
    params = dict(
        team_id=TEAM_ID, client_id=CLIENT_ID, key_id=KEY_ID, private_key=p8_pem
    )
    params.update(kwargs)
    return generate_client_secret(**params)


# ── client_secret ────────────────────────────────────────────────────────────


def test_client_secret_header_and_claims(p8_keypair):
    """Header.kid + ES256 and the iss/sub/aud claims are exactly what Apple's
    endpoints require — and the signature verifies against the .p8's public key."""
    pem, public_key = p8_keypair
    secret = _generate(pem)

    header = jwt.get_unverified_header(secret)
    assert header["kid"] == KEY_ID
    assert header["alg"] == "ES256"

    claims = jwt.decode(
        secret, public_key, algorithms=["ES256"], audience=APPLE_AUDIENCE
    )
    assert claims["iss"] == TEAM_ID  # Team id
    assert claims["sub"] == CLIENT_ID  # the app bundle id (native flow)
    assert claims["aud"] == APPLE_AUDIENCE


def test_client_secret_lifetime_is_capped_at_six_months(p8_keypair):
    """Apple rejects a client_secret older than 6 months — an over-long ttl must
    be clamped, not passed through."""
    pem, public_key = p8_keypair
    now = datetime(2026, 6, 27, tzinfo=timezone.utc)
    secret = _generate(pem, ttl_seconds=10 * 365 * 24 * 3600, now=now)
    # verify_exp off: we assert the lifetime *arithmetic* on a fixed clock, not
    # that this fixed-time token is currently fresh.
    claims = jwt.decode(
        secret,
        public_key,
        algorithms=["ES256"],
        audience=APPLE_AUDIENCE,
        options={"verify_exp": False},
    )
    assert claims["exp"] - claims["iat"] == _MAX_CLIENT_SECRET_TTL_SECONDS


def test_client_secret_honours_a_shorter_ttl(p8_keypair):
    """A ttl under the cap is used verbatim (the cap is a ceiling, not a floor)."""
    pem, public_key = p8_keypair
    now = datetime(2026, 6, 27, tzinfo=timezone.utc)
    secret = _generate(pem, ttl_seconds=300, now=now)
    claims = jwt.decode(
        secret,
        public_key,
        algorithms=["ES256"],
        audience=APPLE_AUDIENCE,
        options={"verify_exp": False},
    )
    assert claims["exp"] - claims["iat"] == 300


def test_client_secret_fails_loud_without_key_material():
    """Missing .p8 material must raise, never emit an unsigned/garbage secret."""
    with pytest.raises(RuntimeError):
        generate_client_secret(
            team_id=TEAM_ID, client_id=CLIENT_ID, key_id=KEY_ID, private_key=""
        )


# ── AppleTokenCipher (Fernet) ────────────────────────────────────────────────


def test_cipher_round_trips_the_refresh_token():
    """What we encrypt to the DB is exactly what we decrypt back to call revoke."""
    cipher = AppleTokenCipher(Fernet.generate_key())
    token = "r.AppleRefreshTokenValue.xyz"
    blob = cipher.encrypt(token)
    assert cipher.decrypt(blob) == token


def test_cipher_does_not_store_plaintext():
    """The stored bytes must not contain the refresh token in the clear (F1/F2)."""
    cipher = AppleTokenCipher(Fernet.generate_key())
    token = "r.AppleRefreshTokenValue.xyz"
    blob = cipher.encrypt(token)
    assert token.encode() not in blob


def test_cipher_detects_tampering():
    """Fernet is authenticated — a flipped ciphertext byte must fail to decrypt
    rather than yield a corrupted token."""
    cipher = AppleTokenCipher(Fernet.generate_key())
    blob = bytearray(cipher.encrypt("r.AppleRefreshTokenValue.xyz"))
    blob[-1] ^= 0x01
    with pytest.raises(InvalidToken):
        cipher.decrypt(bytes(blob))


def test_cipher_key_is_not_interchangeable():
    """A token encrypted under one key must not decrypt under another."""
    blob = AppleTokenCipher(Fernet.generate_key()).encrypt("secret")
    with pytest.raises(InvalidToken):
        AppleTokenCipher(Fernet.generate_key()).decrypt(blob)


def test_cipher_fails_loud_without_a_key():
    """No APPLE_TOKEN_ENC_KEY → refuse to construct, so a refresh token is never
    written unencrypted."""
    with pytest.raises(RuntimeError):
        AppleTokenCipher(None)
    with pytest.raises(RuntimeError):
        AppleTokenCipher("")
