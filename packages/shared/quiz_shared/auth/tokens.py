"""Access-token sign/verify — the only place that knows the JWT algorithm.

Promoted from apps/quiz-agent/app/auth/tokens.py in issue #95 Session 1 so
quiz-pack-api can verify the same identity (`GET /v1/orders?mine=1`) without
forking the decode logic. quiz-agent signs and verifies; quiz-pack-api is
verify-only but must share the same AUTH_JWT_SECRET / issuer / audience.

Decision D3 (issue #61): HS256 now, isolated here so a future swap to ES256
(now that a second service verifies, the asymmetric split is the natural next
step) stays a one-file change. Every verify passes an explicit ``algorithms``
allowlist — this single habit closes the ``alg=none`` and algorithm-confusion
attacks.
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
        access_ttl_seconds: int = 900,
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
        self.access_ttl_seconds = access_ttl_seconds  # public: the /auth expires_in

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

    def subject_from_token(self, token: str, *, allow_expired: bool = False) -> str:
        """Return the verified ``sub`` of an access token.

        ``allow_expired`` skips *only* the expiry check — signature, issuer, and
        audience are still enforced, so the subject is still cryptographically
        ours. Used by ``/auth/apple`` to identify which anonymous subject to fold
        into the new account: an authentically-signed but stale anon access token
        still authentically names that anon, and folding its usage is what stops a
        freemium-limit reset by letting the token lapse before upgrading (F3). Not
        an authorization check — use ``decode_access_token`` for that."""
        try:
            payload = jwt.decode(
                token,
                self._secret,
                algorithms=[_ALGORITHM],
                audience=self._audience,
                issuer=self._issuer,
                options={
                    "require": ["exp", "iat", "sub", "jti", "iss", "aud"],
                    "verify_exp": not allow_expired,
                },
            )
        except jwt.PyJWTError as exc:
            raise TokenError(str(exc)) from exc
        return payload["sub"]
