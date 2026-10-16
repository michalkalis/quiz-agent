"""GET /api/v1/admin/worker/heartbeat (#193 — beta hardening, #207 207.5).

The prod-monitor GitHub Action fails (and so emails the founder) when the
worker consuming the order queue has no heartbeat. The incident behind it: the
mba session worker died on a Redis drop and lay dead ~20 h, unseen, because no
order was waiting. The tests pin what makes that alert trustworthy: it fires
with zero orders when the worker is gone, it stays silent for a live worker,
and (#207) the mba backup's heartbeat is reported apart from the Fly worker's,
so a covering backup never hides a dead Fly worker.
"""

from __future__ import annotations

from collections.abc import AsyncIterator

import httpx
import pytest_asyncio
from app.api.deps import get_arq_pool
from app.api.v1.admin_orders import router as admin_orders_router
from app.config import (
    BACKUP_HEALTH_CHECK_KEY,
    WORKER_HEALTH_CHECK_INTERVAL_S,
    Settings,
    get_settings,
)
from arq.constants import default_queue_name
from fastapi import FastAPI

from tests.api.conftest import TEST_ADMIN_KEY

URL = "/api/v1/admin/worker/heartbeat"
ADMIN = {"X-Admin-Key": TEST_ADMIN_KEY}
SESSION_QUEUE = "quiz-pack:session"


class _FakeRedis:
    """Just enough ArqRedis: the remaining TTL (ms) per key, -2 = no key."""

    def __init__(self, ttls_ms: dict[str, int]) -> None:
        self.ttls_ms = ttls_ms

    async def pttl(self, key: str) -> int:
        return self.ttls_ms.get(key, -2)


def _client(order_queue: str, ttls_ms: dict[str, int]) -> httpx.AsyncClient:
    app = FastAPI()
    app.include_router(admin_orders_router, prefix="/api")
    app.dependency_overrides[get_settings] = lambda: Settings(
        admin_api_key=TEST_ADMIN_KEY, order_queue_name=order_queue
    )
    app.dependency_overrides[get_arq_pool] = lambda: _FakeRedis(ttls_ms)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")


@pytest_asyncio.fixture
async def dead_session_worker() -> AsyncIterator[httpx.AsyncClient]:
    async with _client(SESSION_QUEUE, {}) as ac:
        yield ac


async def test_requires_admin_key(dead_session_worker: httpx.AsyncClient) -> None:
    assert (await dead_session_worker.get(URL)).status_code == 401


async def test_dead_session_worker_reported_without_any_order(
    dead_session_worker: httpx.AsyncClient,
) -> None:
    # The 2026-10-08 incident: nothing queued, worker gone — must still show.
    body = (await dead_session_worker.get(URL, headers=ADMIN)).json()

    assert body == {
        "queue_name": SESSION_QUEUE,
        "session_queue": True,
        "heartbeat_age_s": None,
        "backup_heartbeat_age_s": None,
    }


async def test_live_session_worker_reports_its_heartbeat_age() -> None:
    # ARQ wrote the key 10 s ago with TTL = interval + 1 s.
    ttl_ms = (WORKER_HEALTH_CHECK_INTERVAL_S + 1 - 10) * 1000
    async with _client(SESSION_QUEUE, {f"{SESSION_QUEUE}:health-check": ttl_ms}) as ac:
        body = (await ac.get(URL, headers=ADMIN)).json()

    assert body["session_queue"] is True
    assert body["heartbeat_age_s"] == 10


async def test_worker_on_old_hourly_heartbeat_still_counts_as_alive() -> None:
    # Until mba restarts on the new code its worker keeps ARQ's 1 h interval;
    # an alive-but-old worker must not page the founder in the meantime.
    async with _client(SESSION_QUEUE, {f"{SESSION_QUEUE}:health-check": 3_000_000}) as ac:
        body = (await ac.get(URL, headers=ADMIN)).json()

    assert body["heartbeat_age_s"] == 0


async def test_dead_fly_worker_is_reported_even_while_the_backup_covers() -> None:
    # #207: the Fly worker is primary. With it gone the backup may be keeping
    # orders moving, but the founder must still hear the Fly worker is down —
    # so the backup's heartbeat never stands in for the queue's own.
    backup_ttl_ms = (WORKER_HEALTH_CHECK_INTERVAL_S + 1 - 5) * 1000
    async with _client(default_queue_name, {BACKUP_HEALTH_CHECK_KEY: backup_ttl_ms}) as ac:
        body = (await ac.get(URL, headers=ADMIN)).json()

    assert body["queue_name"] == default_queue_name
    assert body["session_queue"] is False
    assert body["heartbeat_age_s"] is None
    assert body["backup_heartbeat_age_s"] == 5


async def test_live_fly_worker_with_backup_down() -> None:
    ttl_ms = (WORKER_HEALTH_CHECK_INTERVAL_S + 1 - 3) * 1000
    async with _client(default_queue_name, {f"{default_queue_name}:health-check": ttl_ms}) as ac:
        body = (await ac.get(URL, headers=ADMIN)).json()

    assert body["heartbeat_age_s"] == 3
    assert body["backup_heartbeat_age_s"] is None
