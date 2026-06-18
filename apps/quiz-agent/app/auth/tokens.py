"""Access-token sign/verify — the only place that knows the JWT algorithm.

Decision D3: HS256 now (single service that both signs and verifies), isolated
here so a future swap to ES256 (when a second service must verify) is a one-file
change. Every verify passes an explicit ``algorithms`` allowlist — this single
habit closes the ``alg=none`` and algorithm-confusion attacks.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import jwt

# Allowlist + minimum-secret length live here, not at call sites.
_ALGORITHM = "HS256"
_MIN_SECRET_LEN = 64


class TokenError(Exception):
    """Raised when an access token fails to verify (expired, tampered,
    wrong issuer/audience, missing claims). Callers map this to HTTP 401."""


class TokenService:
    """Signs and verifies short-lived access JWTs for anonymous subjects."""

    def __init__(
        self,
        *,
        secret: str | None,
        issuer: str,
        audience: str,
        access_ttl_seconds: int,
    ) -> None:
        if not secret:
            raise RuntimeError(
                "AUTH_JWT_SECRET is not set — cannot sign or verify tokens."
            )
        if len(secret) < _MIN_SECRET_LEN:
            raise ValueError(
                f"AUTH_JWT_SECRET must be >= {_MIN_SECRET_LEN} chars (got {len(secret)})."
            )
        self._secret = secret
        self._issuer = issuer
        self._audience = audience
        self._access_ttl = timedelta(seconds=access_ttl_seconds)

    def create_access_token(
        self, subject_id: str, *, now: datetime | None = None
    ) -> str:
        """Mint an access token for ``subject_id`` with a full claim set
        (iss/sub/aud/iat/exp/jti). ``jti`` makes each token individually
        identifiable (revocation/audit hooks later)."""
        issued = now or datetime.now(timezone.utc)
        payload = {
            "iss": self._issuer,
            "sub": subject_id,
            "aud": self._audience,
            "iat": issued,
            "exp": issued + self._access_ttl,
            "jti": uuid.uuid4().hex,
        }
        return jwt.encode(payload, self._secret, algorithm=_ALGORITHM)

    def decode_access_token(self, token: str) -> dict:
        """Verify signature + claims and return the payload. Raises
        ``TokenError`` on any failure. The explicit ``algorithms`` allowlist is
        mandatory (D3)."""
        try:
            return jwt.decode(
                token,
                self._secret,
                algorithms=[_ALGORITHM],
                audience=self._audience,
                issuer=self._issuer,
                options={"require": ["exp", "iat", "sub", "jti", "iss", "aud"]},
            )
        except jwt.PyJWTError as exc:
            raise TokenError(str(exc)) from exc


def build_token_service(settings) -> TokenService:
    """Construct a ``TokenService`` from app settings (``app.config.Settings``)."""
    return TokenService(
        secret=settings.auth_jwt_secret,
        issuer=settings.auth_jwt_issuer,
        audience=settings.auth_jwt_audience,
        access_ttl_seconds=settings.access_token_ttl_seconds,
    )
