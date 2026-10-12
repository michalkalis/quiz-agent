"""A pooled connection the server closed while idle must not fail a quiz start (#200).

Prod 2026-10-12T09:50:37Z: starting a custom pack answered 500 — asyncpg
``InterfaceError: connection is closed`` from ``PgvectorQuestionStore.search``
inside ``/start``. The store built its own engine without ``pool_pre_ping``,
so a connection Postgres (or the Fly proxy) had dropped while the app sat idle
was handed out as if alive and the first query on it failed. Every live engine
now comes from ``quiz_shared.database.engine.build_engine``, which pings on
checkout and transparently replaces a dead connection.

The DB test reproduces the outage for real: it kills the store's pooled
backend from a second connection, then runs the exact read ``/start`` makes.
It needs the test Postgres (CI runs it with ``REQUIRE_DB_TESTS=1``).
"""

from __future__ import annotations

import asyncio
import uuid

import pytest
from sqlalchemy import text

from quiz_shared.database.engine import build_engine
from quiz_shared.database.pgvector_client import PgvectorQuestionStore
from tests.conftest import require_db_url

pytestmark = pytest.mark.asyncio


def _engine_of(store: PgvectorQuestionStore):
    return store._session_factory.kw["bind"]


async def test_store_engine_pings_connections_before_use():
    """Offline guard: the engine behind the live question store pre-pings.
    Building it never connects, so this runs without a database."""
    store = PgvectorQuestionStore(database_url="postgresql+asyncpg://u:p@localhost/db")
    engine = _engine_of(store)
    try:
        assert engine.pool._pre_ping is True
    finally:
        await engine.dispose()


async def test_a_connection_killed_while_idle_is_replaced_not_raised():
    url = require_db_url("pgvector idle-connection recovery")
    store = PgvectorQuestionStore(database_url=url, statement_timeout_ms=4_000)
    killer = build_engine(url)
    try:
        # Warm exactly one pooled connection and learn its server process.
        async with store._session_factory() as session:
            pid = (await session.execute(text("SELECT pg_backend_pid()"))).scalar_one()
            # The per-connection statement timeout must survive the switch to
            # the shared builder — it is what keeps a slow query off the hot path.
            timeout = (await session.execute(text("SHOW statement_timeout"))).scalar()
        assert timeout == "4s"

        # Close it server-side, as an idle timeout would, and wait until it is gone.
        async with killer.connect() as conn:
            await conn.execute(text("SELECT pg_terminate_backend(:pid)"), {"pid": pid})
            for _ in range(100):
                alive = await conn.execute(
                    text("SELECT 1 FROM pg_stat_activity WHERE pid = :pid"),
                    {"pid": pid},
                )
                if alive.first() is None:
                    break
                await asyncio.sleep(0.05)

        # The read /start makes for a pack session: must succeed, not raise.
        found = await store.search(filters={"pack_id": str(uuid.uuid4())}, n_results=1)
        assert found == []
    finally:
        await _engine_of(store).dispose()
        await killer.dispose()
