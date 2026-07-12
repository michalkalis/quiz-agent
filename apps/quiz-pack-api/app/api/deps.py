"""FastAPI dependencies for quiz-pack-api (issue #33 Task 1.9).

Two deps live here:
- `get_jws_verifier`: builds `AppleJWSVerifier` once from settings (root cert is
  loaded from disk once, cached for the process lifetime).
- `get_arq_pool`: returns the ARQ Redis pool stored on `app.state.arq_pool`
  (populated by the lifespan in `main.py`). This makes it easy to override in
  tests via `dependency_overrides` without needing a real Redis connection.
"""

from __future__ import annotations

import asyncio
import base64
import secrets
from functools import lru_cache
from typing import Annotated

from fastapi import Depends, HTTPException, Request, status

from arq import create_pool
from arq.connections import ArqRedis, RedisSettings

from quiz_shared.auth.tokens import TokenError, TokenService

from ..config import Settings, get_settings
from ..storekit import AppleJWSVerifier

# Single-flight guard for lazy pool creation. Without this, concurrent requests
# during an Upstash flake each spawn their own arq retry storm and the 256 MB
# web machine OOMs. See get_arq_pool below.
_arq_pool_lock = asyncio.Lock()


@lru_cache(maxsize=1)
def _build_verifier(
    root_cert_path: str,
    app_bundle_id: str,
    storekit_environment: str,
) -> AppleJWSVerifier:
    return AppleJWSVerifier.from_path(root_cert_path, app_bundle_id, storekit_environment)


def get_jws_verifier(settings: Annotated[Settings, Depends(get_settings)]) -> AppleJWSVerifier:
    """Return a cached `AppleJWSVerifier` built from the current settings."""
    return _build_verifier(
        str(settings.storekit_root_cert_path),
        settings.app_bundle_id,
        settings.storekit_environment,
    )


def _redis_settings_fast_fail(dsn: str) -> RedisSettings:
    """RedisSettings tuned to fail fast under flaky upstreams.

    arq defaults retry 5× and TLS to Upstash makes each attempt ~5 s, so a
    failing `create_pool` blocks a request for ~30 s and holds buffers the
    whole time. With 1 retry and a 2 s timeout, a doomed attempt returns in
    ~2 s — bounded memory, fast 503 to the client.
    """
    rs = RedisSettings.from_dsn(dsn)
    rs.conn_timeout = 2
    rs.conn_retries = 1
    return rs


async def get_arq_pool(request: Request) -> ArqRedis:
    """Return the ARQ pool stored on app state by the lifespan.

    If startup couldn't reach Redis (e.g. Upstash flake during boot), retry
    pool creation on demand so the API recovers without a full machine
    restart. The lock keeps only one create_pool attempt in flight; concurrent
    requests during a flake share its outcome instead of each running their
    own retry storm (which stacked memory enough to OOM the 256 MB web VM).
    """
    pool = request.app.state.arq_pool
    if pool is not None:
        return pool

    settings = get_settings()
    async with _arq_pool_lock:
        pool = request.app.state.arq_pool
        if pool is not None:
            return pool
        try:
            pool = await create_pool(_redis_settings_fast_fail(settings.redis_url))
        except Exception as exc:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="queue backend unavailable",
            ) from exc
        request.app.state.arq_pool = pool
        return pool


def get_redis_url(settings: Annotated[Settings, Depends(get_settings)]) -> str:
    """Return the Redis DSN from settings."""
    return settings.redis_url


def _extract_admin_key(request: Request) -> str | None:
    """Pull the presented admin secret from the request.

    Two carriers (#65): the `X-Admin-Key` header (used by scripts/agents,
    mirrors quiz-agent's `set_premium`) or HTTP Basic auth (so the `/web`
    admin UI stays openable in a browser — any username, password = the key).
    """
    header = request.headers.get("X-Admin-Key")
    if header:
        return header
    authorization = request.headers.get("Authorization", "")
    if authorization.startswith("Basic "):
        try:
            decoded = base64.b64decode(authorization[len("Basic "):]).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            return None
        # "username:password" — the password component is the key.
        return decoded.split(":", 1)[1] if ":" in decoded else decoded
    return None


@lru_cache(maxsize=1)
def _build_token_service(secret: str, issuer: str, audience: str) -> TokenService:
    return TokenService(secret=secret, issuer=issuer, audience=audience)


def require_user(
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
) -> str:
    """Resolve the caller's account id from a quiz-agent bearer JWT (#95).

    Verify-only twin of quiz-agent's `require_bearer_or_grace` — same secret,
    issuer, and audience (Fly secret AUTH_JWT_SECRET must match quiz-agent's).
    No grace path here: order ownership is a hard gate, so an invalid or
    missing token is always 401. Unset secret → 503 (fail closed, mirrors
    `require_admin`).
    """
    subject = _decode_bearer_subject(request, settings)
    if subject is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Bearer token required",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return subject


def optional_user(
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
) -> str | None:
    """Like `require_user` but a missing Authorization header yields None.

    Used by order creation (#95): the admin/founder path works without an
    account, but when the iOS app does send its quiz-agent bearer we link the
    order to that account so it shows up in `GET /v1/orders` (mine). A
    *present but invalid* token is still 401 — silently dropping it would
    orphan the order without anyone noticing.
    """
    return _decode_bearer_subject(request, settings)


def _decode_bearer_subject(request: Request, settings: Settings) -> str | None:
    """Shared bearer decode: None when absent, 401 invalid, 503 unconfigured."""
    authorization = request.headers.get("Authorization", "")
    if not authorization.startswith("Bearer "):
        return None
    if not settings.auth_jwt_secret:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Bearer auth not configured",
        )
    service = _build_token_service(
        settings.auth_jwt_secret,
        settings.auth_jwt_issuer,
        settings.auth_jwt_audience,
    )
    token = authorization[len("Bearer "):]
    try:
        payload = service.decode_access_token(token)
    except TokenError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Invalid bearer token: {exc}",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc
    return payload["sub"]


def admin_key_presented(request: Request) -> bool:
    """True when the request carries an admin credential (#95 founder order
    path) — presence only; validity is `check_admin_key`'s job."""
    return _extract_admin_key(request) is not None


def check_admin_key(request: Request, settings: Settings) -> None:
    """Validate a *presented* admin key or raise (same semantics as
    `require_admin`, callable imperatively where the auth scheme is decided
    per-request rather than per-route — see POST /v1/orders)."""
    configured = settings.admin_api_key
    if not configured:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Admin API not configured",
        )
    presented = _extract_admin_key(request)
    if presented is None or not secrets.compare_digest(presented, configured):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing admin credentials",
            headers={"WWW-Authenticate": "Basic"},
        )


def require_admin(
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
) -> None:
    """Guard admin routes (#65): require a valid `ADMIN_API_KEY`.

    Fails closed: an unset key → 503 (the route is unusable until the Fly
    secret / dev key is set), never silently open. A wrong or absent key →
    401 with `WWW-Authenticate: Basic` so a browser prompts for credentials.
    """
    check_admin_key(request, settings)
