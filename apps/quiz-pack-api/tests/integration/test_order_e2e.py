"""End-to-end integration test: order → worker → SSE stream (issue #33 Task 1.12).

Run locally
-----------
    cd apps/quiz-pack-api
    make dev-db          # starts docker-compose postgres:16 + redis:7
    pytest tests/integration/test_order_e2e.py -v -m integration

CI
--
    GitHub Actions `test-quiz-pack-api` job starts postgres + redis as service
    containers and sets DATABASE_URL / REDIS_URL env vars before running these
    tests (see .github/workflows/backend-ci.yml).

Architecture
------------
The test builds a *minimal* FastAPI app (orders router only) to avoid triggering
module-level ChatOpenAI / SOCKS-proxy init in ``app.api.routes``. The ARQ worker
is run **in-process** via ``arq.worker.run_worker`` started in a background
asyncio task — simpler than a subprocess and avoids port management.

Key 1.11 note: step_log replay entries have ``progress=0`` (the JSONB entries
don't store per-step progress; live pubsub events carry real progress). Tests
assert on ``step`` names for replayed events, and on ``progress`` only for
live events — see comments below.
"""

from __future__ import annotations

import asyncio
import os
import uuid
from typing import AsyncIterator, Optional

import pytest
import pytest_asyncio
import httpx
from fastapi import FastAPI
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.api.deps import get_arq_pool, get_jws_verifier, get_redis_url
from app.api.v1.orders import router as orders_router
from app.db.engine import build_engine, normalize_async_url
from app.db.models.job import GenerationJob
from app.db.models.order import GenerationOrder
from app.db.session import AsyncSessionLocal, get_session
from app.storekit import AppleJWSVerifier
from tests.fixtures.storekit.jws_minter import JWSMinter

pytestmark = pytest.mark.integration

# ---------------------------------------------------------------------------
# Skip guard — all tests in this module need Postgres + Redis
# ---------------------------------------------------------------------------

_DB_URL = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
_REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379/0")


def _check_services() -> Optional[str]:
    """Return a skip reason string if Postgres or Redis are unreachable."""
    if not _DB_URL:
        return (
            "TEST_DATABASE_URL / DATABASE_URL not set. "
            "Run `make dev-db` from apps/quiz-pack-api/ and set the env var."
        )
    # Probe Redis synchronously (cheap, no event loop needed at collection time).
    import socket

    from urllib.parse import urlparse

    parsed = urlparse(_REDIS_URL)
    host = parsed.hostname or "localhost"
    port = parsed.port or 6379
    try:
        with socket.create_connection((host, port), timeout=1):
            pass
    except OSError:
        return f"Redis not reachable at {host}:{port} — run `make dev-db`."
    return None


_SKIP_REASON = _check_services()
if _SKIP_REASON:
    pytest.skip(_SKIP_REASON, allow_module_level=True)

# ---------------------------------------------------------------------------
# Session-scoped fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def minter() -> JWSMinter:
    """Session-scoped JWSMinter — generates test cert chain once per session."""
    return JWSMinter()


@pytest.fixture(scope="session")
def verifier(minter: JWSMinter) -> AppleJWSVerifier:
    return AppleJWSVerifier(minter.root_cert, "com.missinghue.hangs", "Sandbox")


# ---------------------------------------------------------------------------
# Function-scoped DB engine / session
# ---------------------------------------------------------------------------


@pytest_asyncio.fixture
async def engine() -> AsyncIterator[AsyncEngine]:
    eng = build_engine(normalize_async_url(_DB_URL))
    try:
        yield eng
    finally:
        await eng.dispose()


@pytest_asyncio.fixture
async def db_session(engine: AsyncEngine) -> AsyncIterator[AsyncSession]:
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with factory() as s:
        yield s


# ---------------------------------------------------------------------------
# Redis flush between tests to prevent stale JWS cache hits
# ---------------------------------------------------------------------------


@pytest_asyncio.fixture(autouse=True)
async def flush_redis() -> AsyncIterator[None]:
    """FLUSHDB before each test so JWS verify-cache keys don't carry over."""
    from redis.asyncio import Redis

    r = Redis.from_url(_REDIS_URL, decode_responses=True)
    try:
        await r.flushdb()
    finally:
        await r.aclose()
    yield


# ---------------------------------------------------------------------------
# Minimal test app (avoids SOCKS-proxy issue in app.api.routes)
# ---------------------------------------------------------------------------


@pytest_asyncio.fixture
async def test_app(
    engine: AsyncEngine,
    db_session: AsyncSession,
    verifier: AppleJWSVerifier,
) -> AsyncIterator[FastAPI]:
    """FastAPI app with orders router + real ARQ pool (from lifespan)."""
    from arq import create_pool
    from arq.connections import RedisSettings

    arq_pool = await create_pool(RedisSettings.from_dsn(_REDIS_URL))

    async def _override_session() -> AsyncIterator[AsyncSession]:
        yield db_session

    app = FastAPI()
    app.include_router(orders_router)
    app.dependency_overrides[get_session] = _override_session
    app.dependency_overrides[get_jws_verifier] = lambda: verifier
    app.dependency_overrides[get_arq_pool] = lambda: arq_pool
    app.dependency_overrides[get_redis_url] = lambda: _REDIS_URL

    # Also patch AsyncSessionLocal used directly inside the SSE bridge / stream route
    # and the in-process ARQ worker. Pass `engine` (AsyncEngine) directly;
    # `db_session.get_bind()` returns the underlying sync Engine, which
    # `async_sessionmaker` then rejects at session-construction time.
    import app.db.session as _db_session_mod
    import app.api.v1.orders as _orders_mod

    orig_factory = _db_session_mod.AsyncSessionLocal
    test_factory = async_sessionmaker(
        engine,
        class_=AsyncSession,
        expire_on_commit=False,
    )
    _db_session_mod.AsyncSessionLocal = test_factory
    _orders_mod.AsyncSessionLocal = test_factory

    try:
        yield app
    finally:
        _db_session_mod.AsyncSessionLocal = orig_factory
        _orders_mod.AsyncSessionLocal = orig_factory
        await arq_pool.close()


@pytest_asyncio.fixture
async def client(test_app: FastAPI) -> AsyncIterator[httpx.AsyncClient]:
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=test_app),
        base_url="http://test",
    ) as ac:
        yield ac


# ---------------------------------------------------------------------------
# ARQ worker run in-process in a background task
# ---------------------------------------------------------------------------


async def _run_worker_once(redis_url: str) -> None:
    """Run the ARQ worker until the queue is empty (drain mode).

    Uses ``arq.worker.Worker`` directly so we can await completion instead of
    spinning a long-lived background process.  ``burst=True`` exits after all
    queued jobs finish.
    """
    from arq.connections import RedisSettings
    from arq.worker import Worker
    from app.worker.tasks import process_order

    class _TestWorkerSettings:
        redis_settings = RedisSettings.from_dsn(redis_url)
        functions = [process_order]
        max_jobs = 2
        max_tries = 1  # no retries in tests — fail fast
        job_timeout = 60

    worker = Worker(
        functions=[process_order],
        redis_settings=RedisSettings.from_dsn(redis_url),
        max_jobs=2,
        max_tries=1,
        job_timeout=60,
        burst=True,  # exit when queue drained
    )
    await worker.async_run()
    await worker.close()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _order_body(
    tx_id: str = "e2e-tx-001",
    product_id: str = "pack_10",
    prompt: str = "Interesting facts about the solar system",
) -> dict:
    return {
        "transaction_id": tx_id,
        "product_id": product_id,
        "prompt": prompt,
        "language": "en",
        "target_count": 10,
    }


async def _poll_order(
    client: httpx.AsyncClient,
    order_id: str,
    *,
    timeout: float = 30.0,
    interval: float = 0.5,
    terminal: frozenset = frozenset({"delivered", "failed"}),
) -> dict:
    """Poll GET /v1/orders/{order_id} until status is terminal or timeout."""
    deadline = asyncio.get_event_loop().time() + timeout
    while asyncio.get_event_loop().time() < deadline:
        resp = await client.get(f"/v1/orders/{order_id}")
        assert resp.status_code == 200, f"poll failed: {resp.text}"
        data = resp.json()
        if data["status"] in terminal:
            return data
        await asyncio.sleep(interval)
    raise TimeoutError(f"order {order_id} did not reach terminal status within {timeout}s")


async def _collect_sse_events(
    client: httpx.AsyncClient,
    url: str,
    jws: str,
    *,
    last_event_id: Optional[int] = None,
    max_events: int = 20,
    timeout: float = 30.0,
) -> list[dict]:
    """Collect SSE events from the stream, stop on `event: done` or `event: failed`."""
    headers = {"X-StoreKit-JWS": jws}
    if last_event_id is not None:
        headers["Last-Event-ID"] = str(last_event_id)

    events: list[dict] = []
    async with client.stream("GET", url, headers=headers, timeout=timeout) as resp:
        assert resp.status_code == 200, f"SSE stream returned {resp.status_code}"
        current: dict = {}
        async for line in resp.aiter_lines():
            if line.startswith("id:"):
                current["id"] = line[3:].strip()
            elif line.startswith("event:"):
                current["event"] = line[6:].strip()
            elif line.startswith("data:"):
                current["data"] = line[5:].strip()
            elif line == "" and current:
                events.append(current)
                current = {}
                step = events[-1].get("event", "")
                if step in ("done", "failed") or len(events) >= max_events:
                    break
    return events


# ---------------------------------------------------------------------------
# Test 1: full happy-path end-to-end
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.xfail(
    reason="needs HTTP mocks — 2.11b–e wire respx routes for sourcing/generation/verify/score",
    strict=False,
)
async def test_order_e2e_full(
    client: httpx.AsyncClient,
    db_session: AsyncSession,
    minter: JWSMinter,
) -> None:
    """POST /v1/orders → worker → SSE stream delivers ~7 events ending with 'done'.

    Assertions:
    - POST returns 202 with order_id.
    - After worker completes, order.status == 'delivered'.
    - job.total_cost_cents == 0 (Phase-1 stub pipeline must not call paid LLMs).
    - SSE stream has ≥ 5 events including a terminal 'done'.
    - stub questions are created with correct pack_id (actual_count == target_count).
    """
    tx_id = f"e2e-full-{uuid.uuid4().hex[:8]}"
    jws = minter.mint(transaction_id=tx_id, product_id="pack_10")

    # 1. Create the order.
    resp = await client.post(
        "/v1/orders",
        json=_order_body(tx_id=tx_id),
        headers={"X-StoreKit-JWS": jws},
    )
    assert resp.status_code == 202, resp.text
    order_id = resp.json()["order_id"]

    # 2. Run the ARQ worker in-process (burst mode — exits when queue drained).
    await _run_worker_once(_REDIS_URL)

    # 3. Poll until delivered.
    snapshot = await _poll_order(client, order_id, timeout=30.0)
    assert snapshot["status"] == "delivered", f"unexpected status: {snapshot}"

    # 4. Cost guardrail: stub pipeline must cost nothing.
    job_data = snapshot["job"]
    assert job_data is not None
    assert job_data["total_cost_cents"] == 0, (
        f"Phase-1 stub pipeline charged {job_data['total_cost_cents']} cents; "
        "Phase-2 PRs introducing real generation must update this assertion explicitly."
    )

    # 5. Stub questions exist with the correct pack_id.
    from app.db.models import QuestionRow
    from sqlalchemy import func

    pack_id = uuid.UUID(snapshot["pack_id"])
    stmt = select(func.count()).where(QuestionRow.pack_id == pack_id)
    count = (await db_session.execute(stmt)).scalar_one()
    assert count == 10, f"expected 10 stub questions, found {count}"

    # 6. SSE stream: connect after job is done — replay path only.
    stream_url = f"/v1/orders/{order_id}/stream"
    # Note: we need a fresh verifier-cache-friendly connection; flush_redis autouse
    # already ran at test start, so the cache is empty and will be populated on connect.
    events = await _collect_sse_events(client, stream_url, jws, timeout=10.0)

    step_names = [e.get("event") for e in events]
    assert "done" in step_names, f"'done' not in step names: {step_names}"
    assert len(events) >= 5, f"expected ≥ 5 SSE events, got {len(events)}: {step_names}"

    # Replay events come from step_log; progress defaults to 0 there (1.11 note).
    # Verify step names include the expected pipeline stages.
    expected_steps = {"sourcing", "generating", "critiquing", "verifying", "scoring", "persisting", "done"}
    received_steps = set(step_names)
    assert received_steps == expected_steps, (
        f"step mismatch. expected={sorted(expected_steps)}, got={sorted(received_steps)}"
    )


# ---------------------------------------------------------------------------
# Test 2: SSE reconnect with Last-Event-ID resumes without duplicates
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.xfail(
    reason="needs HTTP mocks — 2.11b–e wire respx routes for sourcing/generation/verify/score",
    strict=False,
)
async def test_order_sse_reconnect(
    client: httpx.AsyncClient,
    minter: JWSMinter,
) -> None:
    """Reconnecting with Last-Event-ID resumes at next event; no duplicates.

    Flow:
    1. Create order, run worker.
    2. First SSE connection: collect first 3 events, note IDs.
    3. Reconnect with Last-Event-ID = 2 (0-indexed, so event_id 2 was the last seen).
    4. Collected events must all have event_id > 2; no IDs from the first batch repeat.
    """
    tx_id = f"e2e-resume-{uuid.uuid4().hex[:8]}"
    jws = minter.mint(transaction_id=tx_id, product_id="pack_10")

    resp = await client.post(
        "/v1/orders",
        json=_order_body(tx_id=tx_id),
        headers={"X-StoreKit-JWS": jws},
    )
    assert resp.status_code == 202, resp.text
    order_id = resp.json()["order_id"]

    # Run worker to completion.
    await _run_worker_once(_REDIS_URL)
    snapshot = await _poll_order(client, order_id, timeout=30.0)
    assert snapshot["status"] == "delivered"

    stream_url = f"/v1/orders/{order_id}/stream"

    # First connection: collect all events.
    all_events = await _collect_sse_events(client, stream_url, jws, timeout=10.0)
    assert len(all_events) >= 4, f"need at least 4 events to test reconnect, got {len(all_events)}"

    # Use event_id from the 3rd event (index 2) as the reconnect point.
    last_seen_id = int(all_events[2]["id"])

    # Second connection: resume from last_seen_id.
    resumed_events = await _collect_sse_events(
        client, stream_url, jws, last_event_id=last_seen_id, timeout=10.0
    )
    assert len(resumed_events) > 0, "resumed connection returned no events"

    # All resumed events must have event_id > last_seen_id.
    for ev in resumed_events:
        ev_id = int(ev["id"])
        assert ev_id > last_seen_id, (
            f"duplicate: event_id {ev_id} ≤ last_seen_id {last_seen_id}"
        )

    # The first resumed event_id must be last_seen_id + 1.
    first_resumed_id = int(resumed_events[0]["id"])
    assert first_resumed_id == last_seen_id + 1, (
        f"expected resume at event_id {last_seen_id + 1}, got {first_resumed_id}"
    )

    # "done" must be present in the resumed stream (it's after the reconnect point).
    resumed_steps = [e.get("event") for e in resumed_events]
    assert "done" in resumed_steps, f"'done' not in resumed events: {resumed_steps}"
