"""Async SQLAlchemy engine for the auth/usage tables (issue #60).

Lazily builds one shared async engine + sessionmaker against ``DATABASE_URL``.
Lazy so importing this module never requires Postgres (tests/CLI that don't
touch auth keep working); the engine is only created on first use.

``normalize_async_url`` + the engine-build helper moved to
``quiz_shared.database.engine`` (shared with quiz-pack-api, same asyncpg
sslmode->ssl gotcha); this module keeps its own ``build_engine`` as the
settings-bound factory — quiz-agent fails loud (RuntimeError) on a missing
``DATABASE_URL``, same precedent as ``auth/tokens.py``.
"""

from __future__ import annotations

from quiz_shared.database.engine import build_engine as _shared_build_engine
from quiz_shared.database.engine import normalize_async_url
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from ..config import get_settings

__all__ = ["normalize_async_url", "build_engine", "get_engine", "get_sessionmaker"]


_engine: AsyncEngine | None = None
_sessionmaker: async_sessionmaker[AsyncSession] | None = None


def build_engine(url: str | None = None) -> AsyncEngine:
    settings = get_settings()
    raw = url or settings.database_url
    if not raw:
        raise RuntimeError(
            "DATABASE_URL is not set — auth/usage persistence requires Postgres."
        )
    return _shared_build_engine(
        raw, pool_size=settings.db_pool_size, echo=settings.db_echo
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
