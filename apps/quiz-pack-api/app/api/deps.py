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


def require_admin(
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
) -> None:
    """Guard admin routes (#65): require a valid `ADMIN_API_KEY`.

    Fails closed: an unset key → 503 (the route is unusable until the Fly
    secret / dev key is set), never silently open. A wrong or absent key →
    401 with `WWW-Authenticate: Basic` so a browser prompts for credentials.
    """
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
