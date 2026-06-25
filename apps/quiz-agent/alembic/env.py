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
from quiz_shared.paths import load_dotenv_from_ancestors

# Load the repo `.env` (if present) before reading settings, by walking up from
# this file rather than indexing a fixed parent depth: the local checkout and
# the Docker `/app` image sit at different depths, and the old fixed index
# crashed in-container `alembic upgrade head` with IndexError (#60.P3, twin #70).
load_dotenv_from_ancestors(Path(__file__))

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

# These auth/usage tables are co-located in the shared `quiz-pack-db` cluster
# (issue #60 decision #2 — one cluster, no extra DB bill), the SAME database the
# #36 voice read-path reads `questions` from. quiz-pack-api already owns the
# default `alembic_version` table there (head `1c5e0fa7b3d4`). Two independent
# Alembic histories cannot share one version table — pointing this migration at
# the default would make Alembic fail to locate quiz-pack's revision. So this app
# tracks its own state in a dedicated table; the auth table names are disjoint
# from quiz-pack's, so the two histories coexist cleanly in one database.
VERSION_TABLE = "alembic_version_quiz_agent"


def run_migrations_offline() -> None:
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        version_table=VERSION_TABLE,
    )

    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection: Connection) -> None:
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        version_table=VERSION_TABLE,
    )

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
