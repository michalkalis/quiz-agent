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
        return "postgresql+asyncpg://" + url[len("postgres://"):]
    if url.startswith("postgresql://") and "+asyncpg" not in url.split("://", 1)[0]:
        return "postgresql+asyncpg://" + url[len("postgresql://"):]
    return url


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
