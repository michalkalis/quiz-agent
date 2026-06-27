"""Outbound Apple credentials: the client_secret we sign to call Apple, and the
cipher that protects Apple's refresh token at rest (issue #61, 61.3).

Two concerns, both "secrets we hold for Apple", kept together and reused by the
token-exchange (Session B) and account-delete/revoke (Session C) paths:

- ``generate_client_secret`` — Apple's token and revoke endpoints authenticate
  the client with a short-lived **ES256 JWT** signed by the Sign in with Apple
  ``.p8`` key, NOT a static secret. Header ``kid`` = the key id; ``iss`` = the
  Team id; ``sub`` = the client id (the app bundle id for a native flow);
  ``aud`` = Apple. Apple caps the lifetime at 6 months — we cap it here too
  (F10).
- ``AppleTokenCipher`` — Apple's refresh token is encrypted with **Fernet**
  (symmetric, authenticated) before it touches the DB (F1/F2) and decrypted only
  at ``DELETE /auth/me`` to drive the revoke. Fail-loud if the key is unset, so
  a refresh token is never written in the clear.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import jwt
from cryptography.fernet import Fernet

_ALGORITHM = "ES256"
_APPLE_AUDIENCE = "https://appleid.apple.com"
# Apple rejects a client_secret whose lifetime exceeds 6 months (15,777,000 s).
_MAX_CLIENT_SECRET_TTL_SECONDS = 15_777_000


def _now() -> datetime:
    return datetime.now(timezone.utc)


def generate_client_secret(
    *,
    team_id: str,
    client_id: str,
    key_id: str,
    private_key: str,
    ttl_seconds: int = _MAX_CLIENT_SECRET_TTL_SECONDS,
    now: datetime | None = None,
) -> str:
    """Mint the ES256 client_secret JWT Apple's token/revoke endpoints require.

    ``private_key`` is the ``.p8`` contents (PEM). ``ttl_seconds`` is clamped to
    Apple's 6-month maximum so an over-long value can never produce a token Apple
    rejects.
    """
    if not (team_id and client_id and key_id and private_key):
        raise RuntimeError(
            "Apple Sign in key is not fully configured (need APPLE_SIGNIN_TEAM_ID, "
            "APPLE_SIGNIN_CLIENT_ID, APPLE_SIGNIN_KEY_ID, APPLE_SIGNIN_PRIVATE_KEY)."
        )
    issued = now or _now()
    ttl = min(ttl_seconds, _MAX_CLIENT_SECRET_TTL_SECONDS)
    payload = {
        "iss": team_id,
        "iat": issued,
        "exp": issued + timedelta(seconds=ttl),
        "aud": _APPLE_AUDIENCE,
        "sub": client_id,
    }
    return jwt.encode(
        payload, private_key, algorithm=_ALGORITHM, headers={"kid": key_id}
    )


class AppleTokenCipher:
    """Fernet encrypt/decrypt for Apple's refresh token at rest (F1/F2)."""

    def __init__(self, key: str | bytes | None) -> None:
        if not key:
            raise RuntimeError(
                "APPLE_TOKEN_ENC_KEY is not set — refusing to store an Apple "
                "refresh token without encryption."
            )
        self._fernet = Fernet(key if isinstance(key, bytes) else key.encode())

    def encrypt(self, plaintext: str) -> bytes:
        return self._fernet.encrypt(plaintext.encode())

    def decrypt(self, ciphertext: bytes) -> str:
        return self._fernet.decrypt(ciphertext).decode()


def build_apple_token_cipher(settings) -> AppleTokenCipher:
    """Construct an ``AppleTokenCipher`` from app settings (Session B/C)."""
    return AppleTokenCipher(settings.apple_token_enc_key)
