"""Settings for quiz-pack-api (issue #33 Task 1.3).

DATABASE_URL handling note: the Fly secret is `postgres://...` (libpq form) so
`psql $DATABASE_URL` keeps working from a remote shell, but SQLAlchemy + asyncpg
needs `postgresql+asyncpg://...`. `app.db.engine.normalize_async_url` rewrites
the scheme at engine-build time; settings keep the raw value the user provided.
"""

from __future__ import annotations

from functools import lru_cache
from typing import Optional

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=(".env", "../../.env"),
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    database_url: str = "postgresql+asyncpg://quiz:quiz@localhost:5432/quiz_pack"
    test_database_url: Optional[str] = None
    redis_url: str = "redis://localhost:6379/0"
    db_pool_size: int = 5
    db_echo: bool = False


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
