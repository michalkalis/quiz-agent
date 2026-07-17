"""Async SQLAlchemy engine for the auth/usage tables (issue #60).

Lazily builds one shared async engine + sessionmaker against ``DATABASE_URL``.
Lazy so importing this module never requires Postgres (tests/CLI that don't
touch auth keep working); the engine is only created on first use.
"""

from __future__ import annotations

from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from ..config import get_settings


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


_engine: AsyncEngine | None = None
_sessionmaker: async_sessionmaker[AsyncSession] | None = None


def build_engine(url: str | None = None) -> AsyncEngine:
    settings = get_settings()
    raw = url or settings.database_url
    if not raw:
        raise RuntimeError(
            "DATABASE_URL is not set — auth/usage persistence requires Postgres."
        )
    return create_async_engine(
        normalize_async_url(raw),
        pool_size=settings.db_pool_size,
        echo=settings.db_echo,
        pool_pre_ping=True,
        future=True,
    )


def get_engine() -> AsyncEngine:
    global _engine
    if _engine is None:
        _engine = build_engine()
    return _engine


def get_sessionmaker() -> async_sessionmaker[AsyncSession]:
    global _sessionmaker
    if _sessionmaker is None:
        _sessionmaker = async_sessionmaker(
            get_engine(), expire_on_commit=False, class_=AsyncSession
        )
    return _sessionmaker
