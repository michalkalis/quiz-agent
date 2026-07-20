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
import json
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
from app.config import Settings, get_settings

# GET /v1/orders/{id} requires auth since #95; the poll helper presents this.
_E2E_ADMIN_KEY = "e2e-admin-key"
from app.api.v1.orders import router as orders_router
from app.db.engine import build_engine, normalize_async_url
from app.db.models.job import GenerationJob
from app.db.models.order import GenerationOrder
from app.db.session import AsyncSessionLocal, get_session
from app.storekit import AppleJWSVerifier
from quiz_shared.auth.tokens import TokenService
from tests._isolation import truncate_order_graph
from tests.fixtures.storekit.jws_minter import JWSMinter
from tests.integration.conftest import (
    _ANTHROPIC_MESSAGES_RESPONSE,
    _CRITIQUE_PAYLOAD,
    _SCORING_PAYLOAD,
    _TAVILY_VERIFY_RESPONSE,
    _chat_completion_envelope,
    register_sourcing_mocks,
)

pytestmark = pytest.mark.integration

# #103 F3: order creation now requires a bearer alongside the StoreKit JWS.
_E2E_JWT_SECRET = "order-e2e-test-jwt-secret-" + "x" * 64
_BEARER = {
    "Authorization": (
        "Bearer "
        + TokenService(
            secret=_E2E_JWT_SECRET, issuer="quiz-agent", audience="quiz-agent-clients"
        ).create_access_token("e2e-test-account")
    )
}

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


@pytest_asyncio.fixture(autouse=True)
async def _clean_order_tables(db_session: AsyncSession) -> None:
    """Start each test from an empty order/job/pack/question slate.

    This suite (unlike tests/api's `_clean_orders`) had NO cleanup at all —
    isolation depended entirely on every tx_id being a fresh uuid4, so the
    persistent test DB accumulated every past run's rows forever (backend arch
    review 2026-07-18: per-test isolation gap, same fragility class as the
    order-e2e CI flake, 154b95b). Truncating up front bounds that and matches
    tests/api/tests/db.
    """
    await truncate_order_graph(db_session)


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
    app.dependency_overrides[get_settings] = lambda: Settings(
        admin_api_key=_E2E_ADMIN_KEY, auth_jwt_secret=_E2E_JWT_SECRET
    )

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
# Full-pack generation mock (#103 F5) — the shared `e2e_http_mocks` fixture
# (tests/integration/conftest.py) returns 3 near-duplicate question variants
# per call, which is fine for its other consumers (they only assert "≥1
# survivor") but means DedupStage's in-batch Jaccard check always collapses
# them to ~1 real question. A pack_10 order (target_count=10) then trips the
# new TopUpStage floor (80% of 10) every time — not a regression, but this
# fixture was never asked to deliver a realistic full pack. 10 GENUINELY
# distinct phrasings of the SAME easy-to-verify fact (all answer "three",
# which the shared `_TAVILY_VERIFY_RESPONSE` already supports) let the first
# generation pass alone satisfy target_count, so TopUpStage does 0 rounds —
# this is the intended happy path, not a workaround around the floor.
# ---------------------------------------------------------------------------

_TOPUP_FRIENDLY_QUESTIONS = [
    ("How many hearts does an octopus have?", "https://example.com/octopus-hearts-1"),
    ("An octopus's circulatory system relies on how many separate hearts?", "https://example.com/octopus-hearts-2"),
    ("Marine biologists count how many hearts inside a live octopus?", "https://example.com/octopus-hearts-3"),
    ("A healthy octopus pumps blood using how many hearts?", "https://example.com/octopus-hearts-4"),
    ("Zoology textbooks list how many hearts for the common octopus?", "https://example.com/octopus-hearts-5"),
    ("What number of hearts keeps an octopus's blue blood flowing?", "https://example.com/octopus-hearts-6"),
    ("How many pumping hearts does the octopus species carry?", "https://example.com/octopus-hearts-7"),
    ("Aquarium guides say an octopus has how many hearts?", "https://example.com/octopus-hearts-8"),
    ("Cephalopod anatomy books describe how many hearts in an octopus?", "https://example.com/octopus-hearts-9"),
    ("How many separate hearts circulate blood in an octopus's body?", "https://example.com/octopus-hearts-10"),
]


def _topup_friendly_generation_payload() -> dict:
    questions = [
        {
            "reasoning": {
                "source_fact": "Octopuses possess three hearts and copper-based hemocyanin",
                "pattern_used": "Surprising biology",
                "why_interesting": "Most people assume one heart",
                "universal_appeal": "Anatomy is universally relatable",
                "boring_check": "Pinned to verified zoological fact",
            },
            "question": text,
            "type": "text",
            "correct_answer": "three",
            "possible_answers": None,
            "alternative_answers": ["3"],
            "topic": "Biology",
            "category": "science",
            "difficulty": "medium",
            "tags": ["zoology", "anatomy"],
            "language_dependent": False,
            "age_appropriate": "all",
            "source_url": url,
            "source_excerpt": "Octopuses have three hearts.",
            "self_critique": {
                "surprise_factor": 8,
                "universal_appeal": 9,
                "clever_framing": 7,
                "educational_value": 9,
                "answerability": 9,
                "overall_score": 8.4,
                "reasoning": "Strong universal appeal",
            },
        }
        for text, url in _TOPUP_FRIENDLY_QUESTIONS
    ]
    return {"questions": questions}


def _topup_friendly_openai_dispatch(request: httpx.Request) -> httpx.Response:
    body = json.loads(request.content)
    model = body.get("model", "")
    if "gpt-4o-mini" in model:
        content = json.dumps(_CRITIQUE_PAYLOAD)
    elif "gpt-4o" in model:
        content = json.dumps(_topup_friendly_generation_payload())
    else:
        content = json.dumps(_SCORING_PAYLOAD)
    return httpx.Response(200, json=_chat_completion_envelope(content, model))


@pytest.fixture
def e2e_http_mocks_full(_block_external_http):
    """Like `e2e_http_mocks`, but the generation mock returns enough
    genuinely distinct questions for a real pack_10 order to clear
    TopUpStage's floor on the first pass (see module docstring above)."""
    register_sourcing_mocks(_block_external_http)
    _block_external_http.post("https://api.tavily.com/search").mock(
        return_value=httpx.Response(200, json=_TAVILY_VERIFY_RESPONSE)
    )
    _block_external_http.post("https://api.openai.com/v1/chat/completions").mock(
        side_effect=_topup_friendly_openai_dispatch
    )
    _block_external_http.post("https://api.anthropic.com/v1/messages").mock(
        return_value=httpx.Response(200, json=_ANTHROPIC_MESSAGES_RESPONSE)
    )
    return _block_external_http


# ---------------------------------------------------------------------------
# ARQ worker run in-process in a background task
# ---------------------------------------------------------------------------


async def _run_worker_once(redis_url: str) -> None:
    """Run the ARQ worker until the queue is empty (drain mode).

    Uses ``arq.worker.Worker`` directly so we can await completion instead of
    spinning a long-lived background process.  ``burst=True`` exits after all
    queued jobs finish. ``on_startup`` builds the LLM-backed collaborators
    that ``process_order`` reads from ``ctx`` — without it the orchestrator
    KeyErrors before ever reaching the mocked HTTP routes.
    """
    from arq.connections import RedisSettings
    from arq.worker import Worker
    from app.worker.tasks import process_order
    from app.worker.worker import on_startup

    worker = Worker(
        functions=[process_order],
        redis_settings=RedisSettings.from_dsn(redis_url),
        on_startup=on_startup,
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
    db_session: Optional[AsyncSession] = None,
    timeout: float = 30.0,
    interval: float = 0.5,
    terminal: frozenset = frozenset({"delivered", "failed"}),
) -> dict:
    """Poll GET /v1/orders/{order_id} until status is terminal or timeout.

    The orders router shares the test's ``db_session`` (via the get_session
    dependency override) and that session is built with
    ``expire_on_commit=False``. Once it has loaded the order it keeps returning
    the cached row from its identity map, so it never observes the in-process
    worker's ``delivered``/``failed`` commit (written on a *separate* session on
    the same engine) — and the poll spins until it times out. Pass ``db_session``
    so we expire that identity map before each read and the route reloads fresh
    state from the DB (READ COMMITTED makes the worker's commit visible).
    """
    deadline = asyncio.get_event_loop().time() + timeout
    while asyncio.get_event_loop().time() < deadline:
        if db_session is not None:
            db_session.expire_all()
        resp = await client.get(
            f"/v1/orders/{order_id}", headers={"X-Admin-Key": _E2E_ADMIN_KEY}
        )
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
async def test_order_e2e_full(
    client: httpx.AsyncClient,
    db_session: AsyncSession,
    minter: JWSMinter,
    e2e_http_mocks_full,
) -> None:
    """POST /v1/orders → worker → SSE stream delivers ~7 events ending with 'done'.

    Assertions:
    - POST returns 202 with order_id.
    - After worker completes, order.status == 'delivered'.
    - 0 < job.total_cost_cents < 100 (real pipeline costs something, Phase-2
      sanity ceiling; Phase 3 will tighten with per-tier caps).
    - Every persisted Question has a non-null source_url (F8 enforcement).
    - SSE stream has ≥ 5 events including a terminal 'done'.
    """
    tx_id = f"e2e-full-{uuid.uuid4().hex[:8]}"
    jws = minter.mint(transaction_id=tx_id, product_id="pack_10")

    # 1. Create the order.
    resp = await client.post(
        "/v1/orders",
        json=_order_body(tx_id=tx_id),
        headers={"X-StoreKit-JWS": jws, **_BEARER},
    )
    assert resp.status_code == 202, resp.text
    order_id = resp.json()["order_id"]

    # 2. Run the ARQ worker in-process (burst mode — exits when queue drained).
    await _run_worker_once(_REDIS_URL)

    # 3. Poll until delivered.
    snapshot = await _poll_order(client, order_id, db_session=db_session, timeout=30.0)
    assert snapshot["status"] == "delivered", f"unexpected status: {snapshot}"

    # 4. Cost guardrail: real pipeline costs > 0 but stays under the Phase-2
    # sanity ceiling (100 cents). Phase 3 (#37) tightens this with per-tier caps.
    job_data = snapshot["job"]
    assert job_data is not None
    cost = job_data["total_cost_cents"]
    assert 0 < cost < 100, (
        f"total_cost_cents={cost} outside Phase-2 sanity range (0, 100); "
        "expected real LLM calls (>0) under the per-pack ceiling (<100)."
    )

    # 5. Questions persisted with correct pack_id AND F8: every question must
    #    have a non-null source_url (no LLM-hallucinated attribution).
    from app.db.models import QuestionRow

    pack_id = uuid.UUID(snapshot["pack_id"])
    rows = (
        await db_session.execute(
            select(QuestionRow).where(QuestionRow.pack_id == pack_id)
        )
    ).scalars().all()
    assert len(rows) > 0, f"expected ≥1 question for pack {pack_id}, found 0"
    missing_source = [r.id for r in rows if not r.source_url]
    assert not missing_source, (
        f"F8 violation: {len(missing_source)} questions persisted without "
        f"source_url: {missing_source[:5]}"
    )

    # 6. SSE stream: connect after job is done — replay path only.
    stream_url = f"/v1/orders/{order_id}/stream"
    # Note: we need a fresh verifier-cache-friendly connection; flush_redis autouse
    # already ran at test start, so the cache is empty and will be populated on connect.
    events = await _collect_sse_events(client, stream_url, jws, timeout=10.0)

    step_names = [e.get("event") for e in events]
    assert "done" in step_names, f"'done' not in step names: {step_names}"
    assert len(events) >= 5, f"expected ≥ 5 SSE events, got {len(events)}: {step_names}"

    # Replay events come from step_log; progress defaults to 0 there (1.11 note).
    # Verify step names include the expected pipeline stages. Phase 2 stages
    # per app/orchestrator/stages/*.name + the worker's terminal "done" event;
    # critique runs inside GenerationStage so no separate event. "topup"
    # (#103 F5) always runs — a no-op (0 rounds) when nothing was dropped,
    # which is the case here since the mocked collaborators never drop.
    expected_steps = {
        "sourcing", "generating", "verifying", "scoring", "dedup", "topup",
        "persisting", "done",
    }
    received_steps = set(step_names)
    assert received_steps == expected_steps, (
        f"step mismatch. expected={sorted(expected_steps)}, got={sorted(received_steps)}"
    )


# ---------------------------------------------------------------------------
# Test 2: SSE reconnect with Last-Event-ID resumes without duplicates
# ---------------------------------------------------------------------------


@pytest.mark.integration
async def test_order_sse_reconnect(
    client: httpx.AsyncClient,
    db_session: AsyncSession,
    minter: JWSMinter,
    e2e_http_mocks_full,
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
        headers={"X-StoreKit-JWS": jws, **_BEARER},
    )
    assert resp.status_code == 202, resp.text
    order_id = resp.json()["order_id"]

    # Run worker to completion.
    await _run_worker_once(_REDIS_URL)
    snapshot = await _poll_order(client, order_id, db_session=db_session, timeout=30.0)
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
