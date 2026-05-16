"""FastAPI dependencies for quiz-pack-api (issue #33 Task 1.9).

Two deps live here:
- `get_jws_verifier`: builds `AppleJWSVerifier` once from settings (root cert is
  loaded from disk once, cached for the process lifetime).
- `get_arq_pool`: returns the ARQ Redis pool stored on `app.state.arq_pool`
  (populated by the lifespan in `main.py`). This makes it easy to override in
  tests via `dependency_overrides` without needing a real Redis connection.
"""

from __future__ import annotations

from functools import lru_cache
from typing import Annotated

from fastapi import Depends, HTTPException, Request, status

from arq import create_pool
from arq.connections import ArqRedis, RedisSettings

from ..config import Settings, get_settings
from ..storekit import AppleJWSVerifier


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


async def get_arq_pool(request: Request) -> ArqRedis:
    """Return the ARQ pool stored on app state by the lifespan.

    If startup couldn't reach Redis (e.g. Upstash flake during boot), retry pool
    creation on demand so the API recovers without a full machine restart.
    """
    pool = request.app.state.arq_pool
    if pool is not None:
        return pool
    settings = get_settings()
    try:
        pool = await create_pool(RedisSettings.from_dsn(settings.redis_url))
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
