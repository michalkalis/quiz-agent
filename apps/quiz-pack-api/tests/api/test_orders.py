"""Tests for POST /v1/orders and GET /v1/orders/{order_id} (issue #33 Task 1.9).

Uses httpx.AsyncClient against a minimal test app that mounts only the
v1/orders router — avoids triggering module-level service instantiation in the
legacy `app.api.routes` router (which requires OPENAI_API_KEY at import time).

Overrides:
- DB session → test-database (TEST_DATABASE_URL).
- JWS verifier → in-memory test cert chain (no Apple cert file required).
- ARQ pool → MagicMock (no real Redis required).

Bring up the local test DB first: `make dev-db` from apps/quiz-pack-api/.
"""

from __future__ import annotations

import os
import subprocess
import sys
import uuid
from pathlib import Path
from typing import AsyncIterator
from unittest.mock import AsyncMock, MagicMock

import pytest
import pytest_asyncio
import httpx
from fastapi import FastAPI
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.api.deps import get_arq_pool, get_jws_verifier
from app.api.v1.orders import router as orders_router
from app.db.engine import build_engine, normalize_async_url
from app.db.models.job import GenerationJob
from app.db.models.order import GenerationOrder
from app.db.session import get_session
from app.storekit import AppleJWSVerifier
from tests.storekit._chain_fixtures import JWSFactory, TestChain

APP_ROOT = Path(__file__).resolve().parents[2]


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module", autouse=True)
def _alembic_head() -> None:
    """Bring the test DB to head once per module so tables exist.

    Mirrors tests/db and tests/worker: these API tests live in tests/api/, which
    pytest collects before tests/db/, so without this they would run against an
    unmigrated DB on a fresh host (issue #73). Idempotent — a no-op once at head.
    """
    raw = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not raw:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    env = os.environ.copy()
    env["DATABASE_URL"] = raw
    subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        cwd=APP_ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )


@pytest_asyncio.fixture
async def test_engine() -> AsyncIterator[AsyncEngine]:
    raw = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not raw:
        pytest.skip("TEST_DATABASE_URL not set — skipping DB-backed tests")
    eng = build_engine(normalize_async_url(raw))
    yield eng
    await eng.dispose()


@pytest_asyncio.fixture
async def test_session(test_engine: AsyncEngine) -> AsyncIterator[AsyncSession]:
    factory = async_sessionmaker(test_engine, class_=AsyncSession, expire_on_commit=False)
    async with factory() as s:
        yield s


@pytest_asyncio.fixture(autouse=True)
async def _clean_orders(test_session: AsyncSession) -> AsyncIterator[None]:
    """Start each test from an empty orders/jobs slate.

    These tests POST with fixed transaction_ids, and the orders endpoint is
    idempotent on transaction_id (returns 200 for an existing tx). Against the
    persistent test DB, rows left by a prior gate run would turn the expected
    202 into 200 — so the suite must be re-runnable, not just pass once. Other
    DB-test modules clean up per-id; this module truncates because order_ids are
    server-generated and not all surface to the test. CASCADE clears any
    dependent pack/question rows too.
    """
    await test_session.execute(
        text("TRUNCATE generation_orders, generation_jobs RESTART IDENTITY CASCADE")
    )
    await test_session.commit()
    yield


@pytest.fixture
def arq_mock() -> MagicMock:
    pool = MagicMock()
    pool.enqueue_job = AsyncMock(return_value=None)
    return pool


@pytest_asyncio.fixture
async def client(
    test_session: AsyncSession,
    test_chain: TestChain,
    arq_mock: MagicMock,
) -> AsyncIterator[httpx.AsyncClient]:
    """Async HTTP client wired against a minimal test app."""
    verifier = AppleJWSVerifier(
        test_chain.root_cert,
        "com.missinghue.hangs",
        "Sandbox",
    )

    async def _override_session() -> AsyncIterator[AsyncSession]:
        yield test_session

    test_app = FastAPI()
    test_app.include_router(orders_router)
    test_app.dependency_overrides[get_session] = _override_session
    test_app.dependency_overrides[get_jws_verifier] = lambda: verifier
    test_app.dependency_overrides[get_arq_pool] = lambda: arq_mock

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=test_app),
        base_url="http://test",
    ) as ac:
        yield ac


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _valid_body(tx_id: str = "1000000123456789", product_id: str = "pack_20") -> dict:
    return {
        "transaction_id": tx_id,
        "product_id": product_id,
        "prompt": "Interesting facts about the solar system",
        "language": "en",
        "target_count": 20,
    }


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_create_order_happy_path_202(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    arq_mock: MagicMock,
) -> None:
    """POST with a valid JWS returns 202; DB row has status='in_progress',
    target_count=20 (server-derived for pack_20), job_id set, and ARQ
    enqueue_job was called once with ('process_order', <order_id>).
    """
    jws = make_jws()  # default: transactionId=1000000123456789, productId=pack_20
    resp = await client.post("/v1/orders", json=_valid_body(), headers={"X-StoreKit-JWS": jws})
    assert resp.status_code == 202, resp.text

    body = resp.json()
    assert "order_id" in body
    assert body["status"] == "in_progress"
    order_id = uuid.UUID(body["order_id"])

    # DB assertions
    test_session.expire_all()  # flush session cache to read committed data
    stmt = select(GenerationOrder).where(GenerationOrder.id == order_id)
    order = (await test_session.execute(stmt)).scalars().first()
    assert order is not None
    assert order.status == "in_progress"
    assert order.target_count == 20  # server-derived, not from body
    assert order.job_id is not None

    # ARQ assertions — exactly one enqueue call with the right args
    arq_mock.enqueue_job.assert_awaited_once_with("process_order", str(order_id))


@pytest.mark.asyncio
async def test_create_order_idempotent_200(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    arq_mock: MagicMock,
) -> None:
    """Second POST with the same JWS returns 200 with the same order_id; ARQ
    enqueue_job is NOT called again (idempotency).
    """
    jws = make_jws(payload_overrides={"transactionId": "idempotent-tx-1"})
    body = _valid_body(tx_id="idempotent-tx-1")

    resp1 = await client.post("/v1/orders", json=body, headers={"X-StoreKit-JWS": jws})
    assert resp1.status_code == 202, resp1.text
    order_id_1 = resp1.json()["order_id"]

    resp2 = await client.post("/v1/orders", json=body, headers={"X-StoreKit-JWS": jws})
    assert resp2.status_code == 200, resp2.text
    assert resp2.json()["order_id"] == order_id_1

    # Only one enqueue from the first call
    assert arq_mock.enqueue_job.await_count == 1


@pytest.mark.asyncio
async def test_create_order_body_mismatch_400(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
) -> None:
    """Body transaction_id differs from JWS payload → 400."""
    jws = make_jws(payload_overrides={"transactionId": "jws-tx-id"})
    body = _valid_body(tx_id="different-tx-id")  # mismatch
    resp = await client.post("/v1/orders", json=body, headers={"X-StoreKit-JWS": jws})
    assert resp.status_code == 400
    assert "JWS payload does not match body" in resp.json()["detail"]


@pytest.mark.asyncio
async def test_create_order_unknown_product_400(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
) -> None:
    """Unknown product_id → 400."""
    tx_id = "tx-unknown-product"
    jws = make_jws(payload_overrides={"transactionId": tx_id, "productId": "pack_99"})
    body = _valid_body(tx_id=tx_id, product_id="pack_99")
    resp = await client.post("/v1/orders", json=body, headers={"X-StoreKit-JWS": jws})
    assert resp.status_code == 400
    assert "unknown product_id" in resp.json()["detail"]


@pytest.mark.asyncio
async def test_create_order_bad_language_422(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
) -> None:
    """Unsupported language code → 422."""
    jws = make_jws(payload_overrides={"transactionId": "tx-bad-lang"})
    body = {**_valid_body(tx_id="tx-bad-lang"), "language": "de"}
    resp = await client.post("/v1/orders", json=body, headers={"X-StoreKit-JWS": jws})
    assert resp.status_code == 422
    assert "language" in resp.json()["detail"]


@pytest.mark.asyncio
async def test_create_order_prompt_too_short_422(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
) -> None:
    """Prompt under 10 chars → 422."""
    jws = make_jws(payload_overrides={"transactionId": "tx-short-prompt"})
    body = {**_valid_body(tx_id="tx-short-prompt"), "prompt": "hi"}
    resp = await client.post("/v1/orders", json=body, headers={"X-StoreKit-JWS": jws})
    assert resp.status_code == 422
    assert "prompt" in resp.json()["detail"]


@pytest.mark.asyncio
async def test_create_order_missing_header_401(
    client: httpx.AsyncClient,
) -> None:
    """No X-StoreKit-JWS header → 401."""
    resp = await client.post("/v1/orders", json=_valid_body())
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_get_order_not_found_404(
    client: httpx.AsyncClient,
) -> None:
    """GET with a random UUID → 404."""
    resp = await client.get(f"/v1/orders/{uuid.uuid4()}")
    assert resp.status_code == 404


@pytest.mark.asyncio
async def test_get_order_happy(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
) -> None:
    """After a successful POST, GET returns the order with job snapshot
    (status='queued', progress=0).
    """
    tx_id = "tx-get-happy"
    jws = make_jws(payload_overrides={"transactionId": tx_id})
    post_resp = await client.post(
        "/v1/orders", json=_valid_body(tx_id=tx_id), headers={"X-StoreKit-JWS": jws}
    )
    assert post_resp.status_code == 202, post_resp.text
    order_id = post_resp.json()["order_id"]

    get_resp = await client.get(f"/v1/orders/{order_id}")
    assert get_resp.status_code == 200, get_resp.text

    data = get_resp.json()
    assert data["order_id"] == order_id
    assert data["status"] == "in_progress"
    assert data["product_id"] == "pack_20"
    assert data["target_count"] == 20
    assert data["language"] == "en"

    job = data["job"]
    assert job is not None
    # job starts as "queued"; order transitions to in_progress after the POST enqueue
    assert job["status"] == "queued"
    assert job["progress"] == 0
