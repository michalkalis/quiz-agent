"""Pytest fixtures for quiz-pack-api (issue #33 Task 1.3).

The async fixtures here target `TEST_DATABASE_URL` so the dev DB stays untouched.
Bring up the local stack first: `make dev-db` from `apps/quiz-pack-api/`.

`test_chain` and `make_jws` are promoted from `tests/storekit/conftest.py` so
that the API tests in `tests/api/` can also use them without a re-import.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import AsyncIterator

import pytest_asyncio
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

# Pin the LLM gateway to `direct` for the whole suite BEFORE loading .env or
# importing the factory. The tests mock canonical provider endpoints
# (api.openai.com, api.anthropic.com) and the model-unavailable fail-safes
# assume direct routing. A host whose .env sets LLM_GATEWAY=openrouter (e.g. the
# agent Mac `mba`, issue #73) would otherwise point the client at openrouter.ai
# so every mock misses → APIConnectionError / non-fail-safe verdicts. Forcing it
# here keeps the suite hermetic and identical across machines.
os.environ["LLM_GATEWAY"] = "direct"

try:
    from dotenv import load_dotenv

    repo_root = Path(__file__).resolve().parents[3]
    load_dotenv(repo_root / ".env", override=False)
except ImportError:
    pass

from app.db.engine import build_engine, normalize_async_url

# Promote storekit fixtures (test_chain, make_jws) so tests/api/ + tests/storekit/
# can use them. The fixtures live in tests/storekit/_chain_fixtures.py (NOT
# tests/storekit/conftest.py) so pytest doesn't try to register the same module
# twice — once via conftest auto-discovery, once via pytest_plugins.
pytest_plugins = ["tests.storekit._chain_fixtures"]


def _resolve_test_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not url:
        raise RuntimeError(
            "TEST_DATABASE_URL (or DATABASE_URL fallback) must be set for db tests."
        )
    return normalize_async_url(url)


@pytest_asyncio.fixture
async def engine() -> AsyncIterator[AsyncEngine]:
    eng = build_engine(_resolve_test_url())
    try:
        yield eng
    finally:
        await eng.dispose()


@pytest_asyncio.fixture
async def session(engine: AsyncEngine) -> AsyncIterator[AsyncSession]:
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with factory() as s:
        yield s
