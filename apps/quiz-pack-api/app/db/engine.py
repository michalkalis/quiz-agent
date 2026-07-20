"""Async SQLAlchemy engine for quiz-pack-api (issue #33 Task 1.3).

``normalize_async_url`` + the engine-build helper moved to
``quiz_shared.database.engine`` (shared with quiz-agent, same asyncpg
sslmode->ssl gotcha); this module keeps its own ``build_engine`` as the
settings-bound factory — pack falls back to its local-dev default URL when
unset, same precedent as ``auth/tokens.py``.
"""

from __future__ import annotations

from quiz_shared.database.engine import build_engine as _shared_build_engine
from quiz_shared.database.engine import normalize_async_url
from sqlalchemy.ext.asyncio import AsyncEngine

from ..config import get_settings

__all__ = ["normalize_async_url", "build_engine", "engine"]


def build_engine(url: str | None = None) -> AsyncEngine:
    settings = get_settings()
    raw = url or settings.database_url
    return _shared_build_engine(
        raw, pool_size=settings.db_pool_size, echo=settings.db_echo
    )


engine: AsyncEngine = build_engine()
