"""Integration tests for POST /v1/orders/{id}/retry (issue #36 task 2.18).

Covers the four branches called out in the task spec:
- success: failed order with retry_count < 3 → 202
- 409 conflict: order.status != 'failed'
- 422 unprocessable: retry_count already at the cap (3)
- 401 unauthorized: missing X-StoreKit-JWS header

Real Postgres + Redis are required (JWS verify cache + FOR UPDATE row lock).
Tests skip cleanly when those services aren't reachable, mirroring
``test_order_e2e.py``.
"""

from __future__ import annotations

import os
import uuid
from datetime import datetime, timezone
from typing import AsyncIterator, Optional
from unittest.mock import AsyncMock, MagicMock

import httpx
import pytest
import pytest_asyncio
from fastapi import FastAPI
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app import order_budget
from app.api.deps import get_arq_pool, get_jws_verifier, get_redis_url
from app.api.v1.orders import router as orders_router
from app.config import Settings, get_settings
from app.db.engine import build_engine, normalize_async_url
from app.db.models.job import GenerationJob
from app.db.models.order import GenerationOrder
from app.db.session import get_session
from app.storekit import AppleJWSVerifier
from quiz_shared.auth.tokens import TokenService
from tests._isolation import truncate_order_graph
from tests.storekit._chain_fixtures import JWSFactory, TestChain

pytestmark = pytest.mark.integration

_DB_URL = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
_REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379/0")

# #103 F3: order creation now requires a bearer. This module doesn't override
# `get_settings` elsewhere, so a known JWT secret is set here for the test app.
_JWT_SECRET = "order-retry-test-jwt-secret-" + "x" * 64
_BEARER = {
    "Authorization": (
        "Bearer "
        + TokenService(
            secret=_JWT_SECRET, issuer="quiz-agent", audience="quiz-agent-clients"
        ).create_access_token("retry-test-account")
    )
}


def _check_services() -> Optional[str]:
    if not _DB_URL:
        return "TEST_DATABASE_URL / DATABASE_URL not set."
    import socket
    from urllib.parse import urlparse

    parsed = urlparse(_REDIS_URL)
    host = parsed.hostname or "localhost"
    port = parsed.port or 6379
    try:
        with socket.create_connection((host, port), timeout=1):
            pass
    except OSError:
        return f"Redis not reachable at {host}:{port}."
    return None


_SKIP_REASON = _check_services()
if _SKIP_REASON:
    pytest.skip(_SKIP_REASON, allow_module_level=True)


# ---------------------------------------------------------------------------
# Fixtures — minimal app (orders router only) wired against real PG + Redis
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

    Mirrors test_order_e2e.py's fixture of the same purpose (backend arch
    review 2026-07-18: per-test isolation gap) — this module also had no
    cleanup, relying solely on fresh uuid4 tx_ids per test.
    """
    await truncate_order_graph(db_session)


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


@pytest.fixture
def arq_mock() -> MagicMock:
    pool = MagicMock()
    pool.enqueue_job = AsyncMock(return_value=None)
    return pool


@pytest_asyncio.fixture
async def client(
    db_session: AsyncSession,
    test_chain: TestChain,
    arq_mock: MagicMock,
) -> AsyncIterator[httpx.AsyncClient]:
    verifier = AppleJWSVerifier(
        test_chain.root_cert,
        "com.missinghue.hangs",
        "Sandbox",
    )

    async def _override_session() -> AsyncIterator[AsyncSession]:
        yield db_session

    app = FastAPI()
    app.include_router(orders_router)
    app.dependency_overrides[get_session] = _override_session
    app.dependency_overrides[get_jws_verifier] = lambda: verifier
    app.dependency_overrides[get_arq_pool] = lambda: arq_mock
    app.dependency_overrides[get_redis_url] = lambda: _REDIS_URL
    app.dependency_overrides[get_settings] = lambda: Settings(auth_jwt_secret=_JWT_SECRET)

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app),
        base_url="http://test",
    ) as ac:
        yield ac


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _order_body(tx_id: str, product_id: str = "pack_10") -> dict:
    return {
        "transaction_id": tx_id,
        "product_id": product_id,
        "prompt": "Interesting facts about the solar system",
        "language": "en",
        "target_count": 10,
    }


async def _post_order(
    client: httpx.AsyncClient, make_jws: JWSFactory, tx_id: str
) -> str:
    jws = make_jws(
        payload_overrides={"transactionId": tx_id, "productId": "pack_10"}
    )
    resp = await client.post(
        "/v1/orders",
        json=_order_body(tx_id),
        headers={"X-StoreKit-JWS": jws, **_BEARER},
    )
    assert resp.status_code == 202, resp.text
    return resp.json()["order_id"]


async def _force_failed(
    engine: AsyncEngine,
    db_session: AsyncSession,
    order_id: str,
    *,
    job_try: int = 3,
) -> None:
    """Drive the order to a REAL terminal-failed state via the runtime's own
    failure handler (`_handle_failure`) — the exact path a genuinely
    exhausted ARQ job takes — instead of hand-forcing `retry_count=0` (a
    state the runtime never produces: `_handle_failure` advances
    `retry_count` on every ended attempt, and an order only reaches 'failed'
    when `job_try >= max_tries` or the lifetime budget is gone, so every real
    failure of a fresh order has `retry_count == 3`; #103 F1, #145).
    `job_try=3` (== `WorkerSettings.max_tries`) reproduces that.
    """
    from sqlalchemy.ext.asyncio import async_sessionmaker

    from app.worker.tasks import _handle_failure

    session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    ctx = {"job_try": job_try, "session_factory": session_factory}
    await _handle_failure(
        ctx,
        uuid.UUID(order_id),
        order_id,
        sink=None,
        exc=RuntimeError("induced failure for retry test"),
    )
    db_session.expire_all()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.integration
async def test_retry_failed_order_returns_202(
    client: httpx.AsyncClient,
    engine: AsyncEngine,
    db_session: AsyncSession,
    make_jws: JWSFactory,
    arq_mock: MagicMock,
) -> None:
    """Happy path: order driven to a REAL terminal 'failed' state (job_try==
    max_tries, exactly what the runtime produces) still has manual_retry_count
    == 0 → 202, state reset, ARQ re-enqueued (#103 F1 regression test: before
    the fix, EVERY genuinely-failed order had retry_count == 3 and this
    endpoint always 422'd)."""
    tx_id = f"retry-ok-{uuid.uuid4().hex[:8]}"
    order_id = await _post_order(client, make_jws, tx_id)
    await _force_failed(engine, db_session, order_id, job_try=3)
    arq_mock.enqueue_job.reset_mock()

    jws = make_jws(
        payload_overrides={"transactionId": tx_id, "productId": "pack_10"}
    )
    before_retry = datetime.now(timezone.utc)
    resp = await client.post(
        f"/v1/orders/{order_id}/retry", headers={"X-StoreKit-JWS": jws}
    )
    assert resp.status_code == 202, resp.text
    body = resp.json()
    assert body["order_id"] == order_id
    assert body["status"] == "in_progress"

    # Deterministic attempt id (adversarial audit 2026-07-30): without it arq
    # minted a random uuid4 per enqueue, so a retry racing the stuck-order sweep
    # ran two paid pipelines for one purchase. #145: the id is keyed on
    # `attempt_seq` (0 → 1 here), a counter that exists only for this — keyed on
    # `retry_count` the endpoint had to zero it, which is what handed every
    # manual retry a fresh 3-attempt paid budget.
    arq_mock.enqueue_job.assert_awaited_once_with(
        "process_order", order_id, _job_id=f"process_order:{order_id}:1"
    )

    # Verify DB state: order back to in_progress, job reset to queued,
    # manual_retry_count++ (the dedicated manual budget), and retry_count
    # ADVANCED (3 from the exhausted sequence + the attempt this retry claims),
    # never reset — it is the order's lifetime attempt counter now (#145).
    db_session.expire_all()
    order = (
        await db_session.execute(
            select(GenerationOrder).where(GenerationOrder.id == uuid.UUID(order_id))
        )
    ).scalars().one()
    job = (
        await db_session.execute(
            select(GenerationJob).where(GenerationJob.id == order.job_id)
        )
    ).scalars().one()
    assert order.status == "in_progress"
    assert job.status == "queued"
    assert job.retry_count == 4
    assert job.attempt_seq == 1
    assert job.manual_retry_count == 1
    assert job.error is None
    assert job.progress == 0
    # Fresh queue handoff (#133 item 1e): the stuck-order sweep gates 'pending'
    # on `enqueued_at`, so a retry that left it at the original purchase time
    # would be classified as stuck by the next tick — a second paid pipeline for
    # this same order, in the window before the flip to 'in_progress'. Compared
    # against a timestamp from *this* clock, not against `created_at`: that one
    # is written by `now()` on the DB server, whose clock runs ~60 ms ahead of
    # the app's inside Docker.
    assert order.enqueued_at >= before_retry


@pytest.mark.integration
async def test_retry_non_failed_returns_409(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    arq_mock: MagicMock,
) -> None:
    """Retry on an in-flight (not failed) order → 409, no re-enqueue."""
    tx_id = f"retry-conflict-{uuid.uuid4().hex[:8]}"
    order_id = await _post_order(client, make_jws, tx_id)
    arq_mock.enqueue_job.reset_mock()

    jws = make_jws(
        payload_overrides={"transactionId": tx_id, "productId": "pack_10"}
    )
    resp = await client.post(
        f"/v1/orders/{order_id}/retry", headers={"X-StoreKit-JWS": jws}
    )
    assert resp.status_code == 409, resp.text
    assert "failed" in resp.json()["detail"]
    arq_mock.enqueue_job.assert_not_awaited()


@pytest.mark.integration
async def test_retry_at_cap_returns_422(
    client: httpx.AsyncClient,
    engine: AsyncEngine,
    db_session: AsyncSession,
    make_jws: JWSFactory,
    arq_mock: MagicMock,
) -> None:
    """manual_retry_count == 3 → 422 (cap reached), no re-enqueue.

    The order is driven to a real terminal 'failed' state (job_try==
    max_tries) first — a stray retry_count==3 no longer gates this endpoint
    (#103 F1) — then manual_retry_count is set to the cap directly, which
    simulates "3 manual retries already used", the thing this test targets.
    """
    tx_id = f"retry-cap-{uuid.uuid4().hex[:8]}"
    order_id = await _post_order(client, make_jws, tx_id)
    await _force_failed(engine, db_session, order_id, job_try=3)
    job = (
        await db_session.execute(
            select(GenerationJob).where(
                GenerationJob.order_id == uuid.UUID(order_id)
            )
        )
    ).scalars().one()
    job.manual_retry_count = 3
    await db_session.commit()
    arq_mock.enqueue_job.reset_mock()

    jws = make_jws(
        payload_overrides={"transactionId": tx_id, "productId": "pack_10"}
    )
    resp = await client.post(
        f"/v1/orders/{order_id}/retry", headers={"X-StoreKit-JWS": jws}
    )
    assert resp.status_code == 422, resp.text
    assert "retry cap" in resp.json()["detail"]
    arq_mock.enqueue_job.assert_not_awaited()


@pytest.mark.integration
async def test_three_manual_retries_keep_distinct_ids_and_a_rising_attempt_count(
    client: httpx.AsyncClient,
    engine: AsyncEngine,
    db_session: AsyncSession,
    make_jws: JWSFactory,
    arq_mock: MagicMock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """#145 F1 regression: `/retry` must not buy a fresh auto-retry budget.

    It used to zero `retry_count` purely to keep the deterministic ARQ job id
    unique across sequences — and that reset was the money hole: one purchase
    could walk through four independent 3-attempt budgets, ~12 full frontier
    pipeline runs (~$4.23 each) for ~€4.99. Uniqueness now comes from
    `attempt_seq`, so the attempt counter is free to be what it claims to be:
    monotonic for the life of the order. The lifetime budget is lifted here so
    this test isolates that one property (its own refusal is covered below).
    """
    monkeypatch.setenv("ORDER_ATTEMPT_BUDGET", "20")
    tx_id = f"retry-monotonic-{uuid.uuid4().hex[:8]}"
    order_id = await _post_order(client, make_jws, tx_id)
    jws = make_jws(payload_overrides={"transactionId": tx_id, "productId": "pack_10"})

    job_ids: list[str] = []
    attempt_counts: list[int] = []
    for _ in range(3):
        # Drive the order back to a REAL terminal failure between retries — the
        # state a customer actually retries from.
        await _force_failed(engine, db_session, order_id, job_try=3)
        arq_mock.enqueue_job.reset_mock()

        resp = await client.post(
            f"/v1/orders/{order_id}/retry", headers={"X-StoreKit-JWS": jws}
        )
        assert resp.status_code == 202, resp.text
        job_ids.append(arq_mock.enqueue_job.await_args.kwargs["_job_id"])

        db_session.expire_all()
        job = (
            await db_session.execute(
                select(GenerationJob).where(
                    GenerationJob.order_id == uuid.UUID(order_id)
                )
            )
        ).scalars().one()
        attempt_counts.append(job.retry_count)

    # Distinct ids: a repeated id would be swallowed by arq as a duplicate, so
    # the customer's retry would silently never run.
    assert len(set(job_ids)) == 3, job_ids
    # Strictly increasing attempts: the whole point — the order's spend is now
    # accountable across manual retries instead of restarting each time.
    assert attempt_counts == sorted(set(attempt_counts)), attempt_counts


@pytest.mark.integration
async def test_lifetime_attempt_budget_ends_the_order_before_four_budgets(
    client: httpx.AsyncClient,
    engine: AsyncEngine,
    db_session: AsyncSession,
    make_jws: JWSFactory,
    arq_mock: MagicMock,
) -> None:
    """#145 F1: an order that fails every attempt must die once, at the
    lifetime budget — not after four independent 3-attempt budgets.

    Before the fix the manual cap (3) was the only limit and each retry bought
    a fresh auto budget, so this loop would have run to ~12 paid pipeline runs.
    Here the shared budget refuses *before* the manual cap is even reached, and
    leaves the order terminal + refund-eligible."""
    tx_id = f"retry-lifetime-{uuid.uuid4().hex[:8]}"
    order_id = await _post_order(client, make_jws, tx_id)
    jws = make_jws(payload_overrides={"transactionId": tx_id, "productId": "pack_10"})

    accepted = 0
    for _ in range(3):  # the manual cap — the only limit before #145
        await _force_failed(engine, db_session, order_id, job_try=3)
        resp = await client.post(
            f"/v1/orders/{order_id}/retry", headers={"X-StoreKit-JWS": jws}
        )
        if resp.status_code == 422:
            break
        assert resp.status_code == 202, resp.text
        accepted += 1
    else:
        pytest.fail("lifetime attempt budget never refused a retry")

    assert accepted < 3, "the shared budget must bind before the manual cap"
    assert "attempt budget" in resp.json()["detail"]

    db_session.expire_all()
    order = (
        await db_session.execute(
            select(GenerationOrder).where(GenerationOrder.id == uuid.UUID(order_id))
        )
    ).scalars().one()
    job = (
        await db_session.execute(
            select(GenerationJob).where(GenerationJob.order_id == uuid.UUID(order_id))
        )
    ).scalars().one()
    assert order.status == "failed"
    assert order.refund_eligible is True
    assert job.retry_count >= order_budget.attempt_budget()


@pytest.mark.integration
async def test_retry_over_spend_ceiling_returns_422_and_marks_refund_eligible(
    client: httpx.AsyncClient,
    engine: AsyncEngine,
    db_session: AsyncSession,
    make_jws: JWSFactory,
    arq_mock: MagicMock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """#145: a retry that would push one purchase past its spend ceiling is
    refused, loudly, and the order ends refund-eligible.

    The manual cap alone cannot do this: three retries of a cheap failure are
    fine, three retries that each burn a full frontier run are ~$12 against a
    ~€4.99 sale. The refusal must name the ceiling (the client shows it, and
    the Sentry event is what tells us the ceiling is set wrong)."""
    import sentry_sdk

    captured: list[tuple[str, str]] = []
    monkeypatch.setattr(
        sentry_sdk,
        "capture_message",
        lambda message, level=None, **kw: captured.append((message, level)),
    )

    tx_id = f"retry-ceiling-{uuid.uuid4().hex[:8]}"
    order_id = await _post_order(client, make_jws, tx_id)
    await _force_failed(engine, db_session, order_id, job_try=3)

    job = (
        await db_session.execute(
            select(GenerationJob).where(GenerationJob.order_id == uuid.UUID(order_id))
        )
    ).scalars().one()
    ceiling = order_budget.spend_ceiling_cents("pack_10")
    job.cumulative_cost_cents = ceiling
    await db_session.commit()
    arq_mock.enqueue_job.reset_mock()

    jws = make_jws(payload_overrides={"transactionId": tx_id, "productId": "pack_10"})
    resp = await client.post(
        f"/v1/orders/{order_id}/retry", headers={"X-StoreKit-JWS": jws}
    )

    assert resp.status_code == 422, resp.text
    detail = resp.json()["detail"]
    assert "ceiling" in detail and str(ceiling) in detail
    # No fourth paid pipeline for this purchase.
    arq_mock.enqueue_job.assert_not_awaited()

    db_session.expire_all()
    order = (
        await db_session.execute(
            select(GenerationOrder).where(GenerationOrder.id == uuid.UUID(order_id))
        )
    ).scalars().one()
    assert order.status == "failed"
    assert order.refund_eligible is True

    assert len(captured) == 1
    message, level = captured[0]
    assert str(order_id) in message
    assert str(ceiling) in message
    assert level == "error"


@pytest.mark.integration
async def test_retry_missing_jws_returns_401(
    client: httpx.AsyncClient,
    engine: AsyncEngine,
    db_session: AsyncSession,
    make_jws: JWSFactory,
    arq_mock: MagicMock,
) -> None:
    """No X-StoreKit-JWS header → 401, no DB or ARQ side effects."""
    tx_id = f"retry-noauth-{uuid.uuid4().hex[:8]}"
    order_id = await _post_order(client, make_jws, tx_id)
    await _force_failed(engine, db_session, order_id, job_try=3)
    arq_mock.enqueue_job.reset_mock()

    resp = await client.post(f"/v1/orders/{order_id}/retry")
    assert resp.status_code == 401, resp.text
    arq_mock.enqueue_job.assert_not_awaited()
