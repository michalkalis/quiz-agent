"""Async SQLAlchemy engine for quiz-pack-api (issue #33 Task 1.3)."""

from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from ..config import get_settings


def normalize_async_url(url: str) -> str:
    """Rewrite libpq-style URLs (`postgres://`, `postgresql://`) into asyncpg form.

    Fly stores `DATABASE_URL` as libpq so `fly ssh console` + `psql $DATABASE_URL`
    keep working; SQLAlchemy + asyncpg requires the explicit driver in the scheme.
    """
    if url.startswith("postgres://"):
        url = "postgresql+asyncpg://" + url[len("postgres://") :]
    elif url.startswith("postgresql://") and "+asyncpg" not in url.split("://", 1)[0]:
        url = "postgresql+asyncpg://" + url[len("postgresql://") :]
    # `fly postgres attach` appends the libpq-only `?sslmode=disable` param,
    # which asyncpg's connect() rejects with a TypeError. asyncpg takes the
    # same sslmode VALUES under its `ssl` argument, so rename the key and keep
    # the value — dropping it instead makes asyncpg default to `prefer` and
    # the flycast LB hard-resets the TLS handshake (ConnectionResetError).
    # `channel_binding` has no asyncpg equivalent and is dropped.
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


def build_engine(url: str | None = None) -> AsyncEngine:
    settings = get_settings()
    raw = url or settings.database_url
    return create_async_engine(
        normalize_async_url(raw),
        pool_size=settings.db_pool_size,
        echo=settings.db_echo,
        pool_pre_ping=True,
        future=True,
    )


engine: AsyncEngine = build_engine()
