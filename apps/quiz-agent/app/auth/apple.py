"""Apple identity-token verification for Sign in with Apple (issue #61, 61.2).

This is the inbound trust boundary: the iOS app sends an Apple ``id_token`` and
we must prove it was minted by Apple for *our* app and *this* sign-in attempt
before we create or unlock an account. Mirrors the discipline in
``app.auth.tokens``: a single place that knows the algorithm, an explicit
allowlist (no ``alg`` confusion), and a fail-loud error the route maps to 401.

What is checked:

- **Signature** against Apple's published JWKS (RS256 only). Keys are fetched
  from ``https://appleid.apple.com/auth/keys`` over httpx and cached 24h; a
  ``kid`` we have not seen forces one refresh (Apple rotates keys).
- **Issuer** ``https://appleid.apple.com`` and **audience** = the app bundle id
  (for a *native* SIWA flow the ``aud`` is the bundle id, not a Services ID).
- **Expiry** — Apple ``id_token``s live only 5–10 min, so a captured token is
  worthless minutes later.
- **Nonce (F6)** — the most common bug in this flow. The token's ``nonce`` claim
  must equal ``base64url-nopad(sha256(raw_nonce))`` — NOT the raw nonce, NOT its
  hex digest. The client must send exactly that encoding as the request nonce so
  Apple echoes it back here.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
from datetime import datetime, timedelta, timezone

import httpx
import jwt
from jwt.algorithms import RSAAlgorithm

_ALGORITHM = "RS256"
_APPLE_ISSUER = "https://appleid.apple.com"
_APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
_JWKS_CACHE_TTL_SECONDS = 86_400  # 24h — Apple rotates its signing keys rarely


def _now() -> datetime:
    return datetime.now(timezone.utc)


def expected_nonce_claim(raw_nonce: str | bytes) -> str:
    """The value Apple must echo in the ``id_token`` ``nonce`` claim for
    ``raw_nonce`` (decision F6): ``base64url-nopad(sha256(raw_nonce))``.

    The client computes this same transform and sends it as the request nonce;
    matching it here proves the token belongs to the sign-in attempt we expect
    (replay/relay defence). The encoding is load-bearing — raw or hex would
    silently never match and the check would be worthless.
    """
    raw = raw_nonce.encode() if isinstance(raw_nonce, str) else raw_nonce
    digest = hashlib.sha256(raw).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


class AppleVerificationError(Exception):
    """An Apple identity token failed verification (bad signature, wrong
    issuer/audience, expired, or nonce mismatch). The caller maps this to HTTP
    401 — never leak which specific step failed."""


class AppleIdentityVerifier:
    """Verifies Apple ``id_token``s against Apple's JWKS with a 24h key cache."""

    def __init__(
        self,
        *,
        audience: str,
        issuer: str = _APPLE_ISSUER,
        jwks_url: str = _APPLE_JWKS_URL,
        http_client: httpx.AsyncClient | None = None,
        jwks_cache_ttl_seconds: int = _JWKS_CACHE_TTL_SECONDS,
    ) -> None:
        if not audience:
            raise RuntimeError(
                "Apple audience (the app bundle id) must be set to verify "
                "identity tokens — see APPLE_SIGNIN_CLIENT_ID."
            )
        self._audience = audience
        self._issuer = issuer
        self._jwks_url = jwks_url
        # Injected in tests (httpx.MockTransport); None → a short-lived client
        # per fetch, which is fine because the result is cached for 24h.
        self._client = http_client
        self._cache_ttl = timedelta(seconds=jwks_cache_ttl_seconds)
        self._jwks: list[dict] | None = None
        self._jwks_fetched_at: datetime | None = None
        self._lock = asyncio.Lock()

    async def verify(self, identity_token: str, *, raw_nonce: str | bytes) -> dict:
        """Verify ``identity_token`` and return its claims (``sub``, ``email``,
        …). Raises ``AppleVerificationError`` on any failure."""
        try:
            header = jwt.get_unverified_header(identity_token)
        except jwt.PyJWTError as exc:
            raise AppleVerificationError("malformed identity token") from exc

        kid = header.get("kid")
        if not kid:
            raise AppleVerificationError("identity token has no key id")

        public_key = await self._signing_key(kid)

        try:
            claims = jwt.decode(
                identity_token,
                public_key,
                algorithms=[_ALGORITHM],
                audience=self._audience,
                issuer=self._issuer,
                options={"require": ["exp", "iat", "iss", "aud", "sub"]},
            )
        except jwt.PyJWTError as exc:
            raise AppleVerificationError(str(exc)) from exc

        # Nonce (F6): constant-time compare against base64url-nopad(sha256(nonce)).
        expected = expected_nonce_claim(raw_nonce)
        actual = claims.get("nonce")
        if not isinstance(actual, str) or not hmac.compare_digest(actual, expected):
            raise AppleVerificationError("nonce mismatch")

        return claims

    async def _signing_key(self, kid: str):
        """Resolve the RSA public key for ``kid``, refreshing the JWKS once if the
        key id is unknown (Apple rotated)."""
        jwk = await self._find_jwk(kid)
        if jwk is None:
            jwk = await self._find_jwk(kid, force_refresh=True)
        if jwk is None:
            raise AppleVerificationError("no matching Apple signing key")
        try:
            return RSAAlgorithm.from_jwk(json.dumps(jwk))
        except (jwt.PyJWTError, ValueError, KeyError) as exc:
            raise AppleVerificationError("invalid Apple signing key") from exc

    async def _find_jwk(self, kid: str, *, force_refresh: bool = False) -> dict | None:
        keys = await self._get_jwks(force_refresh=force_refresh)
        for key in keys:
            if key.get("kid") == kid:
                return key
        return None

    async def _get_jwks(self, *, force_refresh: bool = False) -> list[dict]:
        if not force_refresh and self._cache_fresh():
            return self._jwks  # type: ignore[return-value]
        async with self._lock:
            # Re-check under the lock: a concurrent waiter may have just filled it.
            if not force_refresh and self._cache_fresh():
                return self._jwks  # type: ignore[return-value]
            self._jwks = await self._fetch_jwks()
            self._jwks_fetched_at = _now()
            return self._jwks

    def _cache_fresh(self) -> bool:
        return (
            self._jwks is not None
            and self._jwks_fetched_at is not None
            and _now() - self._jwks_fetched_at < self._cache_ttl
        )

    async def _fetch_jwks(self) -> list[dict]:
        try:
            if self._client is not None:
                resp = await self._client.get(self._jwks_url)
            else:
                async with httpx.AsyncClient(timeout=10.0) as client:
                    resp = await client.get(self._jwks_url)
            resp.raise_for_status()
            keys = resp.json()["keys"]
        except (httpx.HTTPError, KeyError, ValueError) as exc:
            raise AppleVerificationError("could not fetch Apple JWKS") from exc
        if not keys:
            raise AppleVerificationError("Apple JWKS is empty")
        return keys


def build_apple_identity_verifier(settings) -> AppleIdentityVerifier:
    """Construct an ``AppleIdentityVerifier`` from app settings. Wired into the
    app in Session B; raises if the bundle id (audience) is unset."""
    return AppleIdentityVerifier(audience=settings.apple_signin_client_id)
