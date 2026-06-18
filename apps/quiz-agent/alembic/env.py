"""Alembic env for quiz-agent auth/usage tables (issue #60) — async, reads
``DATABASE_URL`` from settings. Mirrors the working quiz-pack-api setup.
"""

from __future__ import annotations

import asyncio
from logging.config import fileConfig
from pathlib import Path

from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config

from alembic import context

try:
    from dotenv import load_dotenv

    repo_root = Path(__file__).resolve().parents[3]
    load_dotenv(repo_root / ".env", override=False)
except ImportError:
    pass

from app.config import get_settings  # noqa: E402
from app.db.base import Base  # noqa: E402
from app.db.engine import normalize_async_url  # noqa: E402
import app.db.models  # noqa: E402,F401  -- imported so metadata is populated

config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# alembic.ini ships a placeholder `sqlalchemy.url`; override it from settings so
# CLI invocations (`alembic upgrade head`) and the app share one source of truth.
_settings = get_settings()
if not _settings.database_url:
    raise RuntimeError("DATABASE_URL must be set to run auth migrations.")
config.set_main_option("sqlalchemy.url", normalize_async_url(_settings.database_url))

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )

    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection: Connection) -> None:
    context.configure(connection=connection, target_metadata=target_metadata)

    with context.begin_transaction():
        context.run_migrations()


async def run_async_migrations() -> None:
    connectable = async_engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)

    await connectable.dispose()


def run_migrations_online() -> None:
    asyncio.run(run_async_migrations())


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
