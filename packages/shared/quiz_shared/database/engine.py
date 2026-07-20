"""Shared async engine construction (promoted from both apps' ``app/db/engine.py``).

The asyncpg sslmode->ssl normalization is prod-critical and was copy-pasted
verbatim in quiz-agent and quiz-pack-api. Promoted here following the
``quiz_shared.auth.tokens`` precedent: shared implementation, thin per-app
wrapper. Each app keeps its own ``build_engine`` that owns URL sourcing
(env var fallback, missing-var behavior) and calls ``build_engine`` here for
the normalization + engine construction that is genuinely identical.
"""

from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine


def normalize_async_url(url: str) -> str:
    """Rewrite libpq-style URLs (`postgres://`, `postgresql://`) into asyncpg form.

    Fly stores ``DATABASE_URL`` as libpq so ``fly ssh console`` + ``psql`` keep
    working; SQLAlchemy + asyncpg requires the explicit driver in the scheme.
    ``fly postgres attach`` also appends the libpq-only ``?sslmode=disable``
    param, which asyncpg's ``connect()`` rejects with a TypeError. asyncpg
    takes the same sslmode VALUES under its ``ssl`` argument, so rename the
    key and keep the value — dropping it instead is wrong: asyncpg then
    defaults to ``prefer`` and the flycast LB hard-resets the TLS handshake
    (ConnectionResetError) instead of refusing politely. ``channel_binding``
    has no asyncpg equivalent and is dropped.
    """
    if url.startswith("postgres://"):
        url = "postgresql+asyncpg://" + url[len("postgres://") :]
    elif url.startswith("postgresql://") and "+asyncpg" not in url.split("://", 1)[0]:
        url = "postgresql+asyncpg://" + url[len("postgresql://") :]
    if "?" not in url:
        return url
    base, query = url.split("?", 1)
    params = []
    for pair in query.split("&"):
        key, _, value = pair.partition("=")
        if key == "channel_binding":
            continue
        if key == "sslmode":
            params.append(f"ssl={value}")
            continue
        params.append(pair)
    return base + ("?" + "&".join(params) if params else "")


def build_engine(url: str, *, pool_size: int = 5, echo: bool = False) -> AsyncEngine:
    """Build an async SQLAlchemy engine against ``url`` (normalized first).

    Callers own URL sourcing (missing-var behavior, local-dev fallback); this
    only handles the sslmode->ssl normalization + engine construction shared
    by both apps.
    """
    return create_async_engine(
        normalize_async_url(url),
        pool_size=pool_size,
        echo=echo,
        pool_pre_ping=True,
        future=True,
    )
