"""Tests for POST /v1/orders and GET /v1/orders/{order_id} (issue #33 Task 1.9).

Uses httpx.AsyncClient against a minimal test app that mounts only the
v1/orders router — avoids triggering module-level service instantiation in the
legacy `app.api.routes` router (which requires OPENAI_API_KEY at import time).
Fixtures (test app, DB, JWS chain overrides) live in tests/api/conftest.py.

Bring up the local test DB first: `make dev-db` from apps/quiz-pack-api/.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

import pytest
import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models.job import GenerationJob
from app.db.models.order import GenerationOrder
from tests.api.conftest import TEST_ADMIN_KEY, _bearer
from tests.storekit._chain_fixtures import JWSFactory

ORDERS_LOGGER = "app.api.v1.orders"

# #103 F3: order creation now requires a bearer alongside the StoreKit JWS —
# every JWS-authenticated create in this module needs one too.
BEARER = _bearer("jws-account-1")


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
    resp = await client.post(
        "/v1/orders", json=_valid_body(), headers={"X-StoreKit-JWS": jws, **BEARER}
    )
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
    # The queue handoff is stamped, not left to chance: the stuck-order sweep
    # gates its 'pending' branch on `enqueued_at` (#133 item 1e).
    assert order.enqueued_at is not None

    # ARQ assertions — exactly one enqueue call with the right args, carrying the
    # deterministic attempt id (adversarial audit 2026-07-30, #133 item 1e).
    # Without an explicit `_job_id` arq mints a random uuid4 per enqueue, so a
    # duplicate enqueue of this same first attempt (a sweep tick racing the
    # handoff) was unrecognisable and ran a second paid pipeline for one
    # purchase. Counters are 0/0 at creation, hence the ':0:0' suffix.
    arq_mock.enqueue_job.assert_awaited_once_with(
        "process_order", str(order_id), _job_id=f"process_order:{order_id}:0:0"
    )


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

    resp1 = await client.post(
        "/v1/orders", json=body, headers={"X-StoreKit-JWS": jws, **BEARER}
    )
    assert resp1.status_code == 202, resp1.text
    order_id_1 = resp1.json()["order_id"]

    resp2 = await client.post(
        "/v1/orders", json=body, headers={"X-StoreKit-JWS": jws, **BEARER}
    )
    assert resp2.status_code == 200, resp2.text
    assert resp2.json()["order_id"] == order_id_1

    # Only one enqueue from the first call
    assert arq_mock.enqueue_job.await_count == 1


@pytest.mark.asyncio
async def test_create_order_body_mismatch_400_is_reported(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    sentry_messages: list[str],
    caplog: pytest.LogCaptureFixture,
) -> None:
    """Body transaction_id differs from JWS payload → 400, with a trail.

    The JWS verified — Apple charged someone — so the reject must leave the
    same reconciliation trail as the other verified-then-refused branches.
    """
    jws = make_jws(payload_overrides={"transactionId": "jws-tx-id"})
    body = _valid_body(tx_id="different-tx-id")  # mismatch
    with caplog.at_level(logging.ERROR, logger=ORDERS_LOGGER):
        resp = await client.post(
            "/v1/orders", json=body, headers={"X-StoreKit-JWS": jws, **BEARER}
        )
    assert resp.status_code == 400
    assert "JWS payload does not match body" in resp.json()["detail"]
    logged = [r.message for r in caplog.records if r.name == ORDERS_LOGGER]
    assert any("body_jws_mismatch" in m and "jws-tx-id" in m for m in logged)
    assert any(
        "body_jws_mismatch" in m and "jws-tx-id" in m for m in sentry_messages
    ), sentry_messages


@pytest.mark.asyncio
async def test_create_order_unknown_product_400_is_reported(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    sentry_messages: list[str],
    caplog: pytest.LogCaptureFixture,
) -> None:
    """Unknown product_id → 400, no row, and a LOUD trail.

    The status code was never the risk here. This branch runs *after* the JWS
    verified, so Apple has already charged the customer — and it used to reject
    with zero trail anywhere (#133 V5: no logger in the module, Sentry reports
    only 5xx, `uvicorn.access` pinned to WARNING). A product tier added in App
    Store Connect ahead of `_PRODUCT_TIERS` would silently take money and leave
    nothing to reconcile or refund from, so the log + Sentry capture (carrying
    transaction_id and product_id) is the part under test.
    """
    tx_id = "tx-unknown-product"
    jws = make_jws(payload_overrides={"transactionId": tx_id, "productId": "pack_99"})
    body = _valid_body(tx_id=tx_id, product_id="pack_99")

    with caplog.at_level(logging.ERROR, logger=ORDERS_LOGGER):
        resp = await client.post(
            "/v1/orders", json=body, headers={"X-StoreKit-JWS": jws, **BEARER}
        )

    assert resp.status_code == 400
    assert "unknown product_id" in resp.json()["detail"]

    # No order row for a rejected purchase (record-first lifecycle is a separate
    # design decision — see _report_verified_reject).
    test_session.expire_all()
    orders = (await test_session.execute(select(GenerationOrder))).scalars().all()
    assert orders == []

    logged = [r.message for r in caplog.records if r.name == ORDERS_LOGGER]
    assert any(
        tx_id in m and "pack_99" in m and "unknown_product_id" in m for m in logged
    ), logged
    assert any(
        tx_id in m and "pack_99" in m and "unknown_product_id" in m
        for m in sentry_messages
    ), sentry_messages


@pytest.mark.asyncio
async def test_create_order_bad_language_422_is_reported(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    sentry_messages: list[str],
    caplog: pytest.LogCaptureFixture,
) -> None:
    """Unsupported language code → 422, no row, and the same LOUD trail.

    Second half of the #133 V5 boundary: a guard violation rejects an
    already-charged transaction exactly like the unmapped-product branch, so it
    must be equally reconcilable. Asserting only one branch would let the
    reporting hook be wired to one call site and silently missing from the other.
    """
    tx_id = "tx-bad-lang"
    jws = make_jws(payload_overrides={"transactionId": tx_id})
    body = {**_valid_body(tx_id=tx_id), "language": "de"}

    with caplog.at_level(logging.ERROR, logger=ORDERS_LOGGER):
        resp = await client.post(
            "/v1/orders", json=body, headers={"X-StoreKit-JWS": jws, **BEARER}
        )

    assert resp.status_code == 422
    assert "language" in resp.json()["detail"]

    test_session.expire_all()
    orders = (await test_session.execute(select(GenerationOrder))).scalars().all()
    assert orders == []

    logged = [r.message for r in caplog.records if r.name == ORDERS_LOGGER]
    assert any(tx_id in m and "guard_violation" in m for m in logged), logged
    assert any(
        tx_id in m and "guard_violation" in m for m in sentry_messages
    ), sentry_messages


@pytest.mark.asyncio
async def test_admin_reject_is_not_reported_as_lost_purchase(
    client: httpx.AsyncClient,
    sentry_messages: list[str],
) -> None:
    """An admin-path reject must NOT page anyone: no Apple charge behind it.

    The trail exists to catch *money* taken for nothing. Firing it for founder
    (#95 admin-key) orders, which are free, would train everyone to ignore it.
    """
    body = {**_valid_body(tx_id="admin-tx-bad-lang"), "language": "de"}
    resp = await client.post(
        "/v1/orders", json=body, headers={"X-Admin-Key": TEST_ADMIN_KEY, **BEARER}
    )
    assert resp.status_code == 422
    assert sentry_messages == []


@pytest.mark.asyncio
async def test_create_order_prompt_too_short_422(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
) -> None:
    """Prompt under 10 chars → 422."""
    jws = make_jws(payload_overrides={"transactionId": "tx-short-prompt"})
    body = {**_valid_body(tx_id="tx-short-prompt"), "prompt": "hi"}
    resp = await client.post(
        "/v1/orders", json=body, headers={"X-StoreKit-JWS": jws, **BEARER}
    )
    assert resp.status_code == 422
    assert "prompt" in resp.json()["detail"]


@pytest.mark.asyncio
async def test_create_order_missing_header_401(
    client: httpx.AsyncClient,
) -> None:
    """No auth at all (no JWS, no admin key, no bearer) → 401."""
    resp = await client.post("/v1/orders", json=_valid_body())
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_create_order_missing_bearer_401(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
) -> None:
    """A valid JWS alone is no longer enough (#103 F3) — without the bearer
    the order would write user_id=NULL and orphan the generated pack."""
    jws = make_jws(payload_overrides={"transactionId": "tx-no-bearer"})
    resp = await client.post(
        "/v1/orders",
        json=_valid_body(tx_id="tx-no-bearer"),
        headers={"X-StoreKit-JWS": jws},  # no bearer
    )
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_create_order_tampered_jws_rejected_no_row(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    arq_mock: MagicMock,
) -> None:
    """A JWS with a flipped signature bit must be rejected AND leave no order.

    The verifier's own unit test proves `verify()` raises; this proves the
    *route* refuses to monetize it. A forged JWS that got past here would be an
    unpaid pack: an order row, a real ARQ job, and a full LLM+Tavily pipeline
    billed to us with no Apple transaction behind it. Asserting "no row" and
    "no enqueue" matters as much as the status code — a rejection that already
    committed the order would still be a free pack via `POST /retry`.
    """
    tx_id = "tx-tampered-signature"
    jws = make_jws(payload_overrides={"transactionId": tx_id}, tamper_signature=True)

    resp = await client.post(
        "/v1/orders",
        json=_valid_body(tx_id=tx_id),
        headers={"X-StoreKit-JWS": jws, **BEARER},
    )
    # 401: the route maps every JWSError except a bundle mismatch to
    # "unauthenticated" (app/api/v1/orders.py create_order).
    assert resp.status_code == 401, resp.text

    test_session.expire_all()
    orders = (await test_session.execute(select(GenerationOrder))).scalars().all()
    assert orders == [], f"forged JWS created order rows: {[o.id for o in orders]}"
    arq_mock.enqueue_job.assert_not_awaited()


@pytest.mark.asyncio
async def test_create_order_wrong_bundle_jws_rejected_no_row(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    arq_mock: MagicMock,
) -> None:
    """A validly-signed JWS for a DIFFERENT app is rejected with no order.

    Same money exposure as a forgery, different attacker: anyone holding a real
    receipt from another App Store app could otherwise redeem it here for a
    generated pack we pay for. Distinct status code (403, not 401) because the
    signature is genuine — this is "not your app", and the route keeps
    `JWSWrongBundle` separate so it reads as a security signal in logs/Sentry.
    """
    tx_id = "tx-wrong-bundle"
    jws = make_jws(
        payload_overrides={"transactionId": tx_id, "bundleId": "com.evil.knockoff"}
    )

    resp = await client.post(
        "/v1/orders",
        json=_valid_body(tx_id=tx_id),
        headers={"X-StoreKit-JWS": jws, **BEARER},
    )
    assert resp.status_code == 403, resp.text

    test_session.expire_all()
    orders = (await test_session.execute(select(GenerationOrder))).scalars().all()
    assert orders == [], f"foreign-bundle JWS created order rows: {[o.id for o in orders]}"
    arq_mock.enqueue_job.assert_not_awaited()


@pytest.mark.asyncio
async def test_create_order_revoked_jws_rejected_no_row(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    arq_mock: MagicMock,
) -> None:
    """A refunded transaction must not buy a pack at the route either.

    `tests/storekit/test_verifier.py` proves `verify()` raises on a revoked
    payload; this proves the money path acts on it — a customer who charged back
    must not walk away with a freshly generated (LLM+Tavily billed) pack. Same
    shape as the tampered/wrong-bundle route tests: status code alone is not
    enough, because a reject that already committed the order would still be a
    free pack via `POST /retry`.
    """
    tx_id = "tx-revoked"
    revoked_ms = int(
        (datetime.now(timezone.utc) - timedelta(days=2)).timestamp() * 1000
    )
    jws = make_jws(
        payload_overrides={
            "transactionId": tx_id,
            "revocationDate": revoked_ms,
            "revocationReason": 1,
        }
    )

    resp = await client.post(
        "/v1/orders",
        json=_valid_body(tx_id=tx_id),
        headers={"X-StoreKit-JWS": jws, **BEARER},
    )
    # 401: JWSRevoked is a JWSError, and the route maps every JWSError except a
    # bundle mismatch to "unauthenticated".
    assert resp.status_code == 401, resp.text
    assert "revoked" in resp.json()["detail"]

    test_session.expire_all()
    orders = (await test_session.execute(select(GenerationOrder))).scalars().all()
    assert orders == [], f"revoked JWS created order rows: {[o.id for o in orders]}"
    arq_mock.enqueue_job.assert_not_awaited()


@pytest.mark.asyncio
async def test_concurrent_duplicate_create_is_idempotent_not_500(
    per_request_client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    arq_mock: MagicMock,
) -> None:
    """Two simultaneous POSTs for ONE purchase → one order, one enqueue, no 500.

    Reproduced in the adversarial audit 2026-07-30 (#133 V4): both requests
    passed the idempotency SELECT (separate transactions, neither seeing the
    other's uncommitted row) and the loser's INSERT tripped the
    `transaction_id` unique index. Nothing caught the `IntegrityError`, so the
    loser got a 500 — a user whose Apple purchase had *succeeded* saw a failed
    order, and Sentry saw an outage that never happened. The client legitimately
    produces this: a retry on a slow response, or StoreKit re-delivering the
    same transaction.

    Note the fixture: this needs `per_request_client` (one session per request).
    The shared-session `client` fixture cannot express the race at all.

    Asserted invariants, in the order they'd bite:
      - neither request 5xx's (the reported defect),
      - exactly one 202 + one 200 — the loser is served the winner's row, not a
        second order for one payment,
      - exactly one order row and one job row (the loser's inserts rolled back
        cleanly, no orphan job),
      - exactly one enqueue — two would run two paid LLM pipelines for one
        purchase.
    """
    tx_id = "tx-concurrent-duplicate"
    jws = make_jws(payload_overrides={"transactionId": tx_id})
    headers = {"X-StoreKit-JWS": jws, **BEARER}
    body = _valid_body(tx_id=tx_id)

    r1, r2 = await asyncio.gather(
        per_request_client.post("/v1/orders", json=body, headers=headers),
        per_request_client.post("/v1/orders", json=body, headers=headers),
    )

    assert sorted([r1.status_code, r2.status_code]) == [200, 202], (
        r1.status_code,
        r1.text,
        r2.status_code,
        r2.text,
    )
    assert r1.json()["order_id"] == r2.json()["order_id"]

    test_session.expire_all()
    orders = (
        (
            await test_session.execute(
                select(GenerationOrder).where(
                    GenerationOrder.transaction_id == tx_id
                )
            )
        )
        .scalars()
        .all()
    )
    assert len(orders) == 1, [o.id for o in orders]
    assert str(orders[0].id) == r1.json()["order_id"]

    jobs = (await test_session.execute(select(GenerationJob))).scalars().all()
    assert len(jobs) == 1, [j.id for j in jobs]

    assert arq_mock.enqueue_job.await_count == 1, (
        f"one purchase enqueued {arq_mock.enqueue_job.await_count} paid pipelines"
    )


@pytest.mark.asyncio
async def test_create_order_enqueue_failure_marks_failed_503(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
    test_session: AsyncSession,
    arq_mock: MagicMock,
) -> None:
    """A Redis blip during enqueue must not strand the order 'pending'
    forever (#103 F4a) — it should come back failed+refund_eligible so the
    client sees a clear error and can retry, instead of a stuck order the
    old code left behind (commit-then-enqueue with no rollback on failure).
    """
    arq_mock.enqueue_job.side_effect = ConnectionError("redis unreachable (simulated)")
    tx_id = "tx-enqueue-fail"
    jws = make_jws(payload_overrides={"transactionId": tx_id})
    resp = await client.post(
        "/v1/orders",
        json=_valid_body(tx_id=tx_id),
        headers={"X-StoreKit-JWS": jws, **BEARER},
    )
    assert resp.status_code == 503, resp.text

    test_session.expire_all()
    stmt = select(GenerationOrder).where(GenerationOrder.transaction_id == tx_id)
    order = (await test_session.execute(stmt)).scalars().first()
    assert order is not None
    assert order.status == "failed"  # NOT stuck 'pending'
    assert order.refund_eligible is True


@pytest.mark.asyncio
async def test_get_order_not_found_404(
    client: httpx.AsyncClient,
) -> None:
    """GET with a random UUID → 404 (as admin — auth is checked first, #95)."""
    resp = await client.get(
        f"/v1/orders/{uuid.uuid4()}", headers={"X-Admin-Key": TEST_ADMIN_KEY}
    )
    assert resp.status_code == 404


@pytest.mark.asyncio
async def test_get_order_happy(
    client: httpx.AsyncClient,
    make_jws: JWSFactory,
) -> None:
    """After a successful POST, GET (admin) returns the order with job snapshot
    (status='queued', progress=0). Admin credential needed since #95 closed the
    Phase-1 unauthenticated read.
    """
    tx_id = "tx-get-happy"
    jws = make_jws(payload_overrides={"transactionId": tx_id})
    post_resp = await client.post(
        "/v1/orders",
        json=_valid_body(tx_id=tx_id),
        headers={"X-StoreKit-JWS": jws, **BEARER},
    )
    assert post_resp.status_code == 202, post_resp.text
    order_id = post_resp.json()["order_id"]

    get_resp = await client.get(
        f"/v1/orders/{order_id}", headers={"X-Admin-Key": TEST_ADMIN_KEY}
    )
    assert get_resp.status_code == 200, get_resp.text

    data = get_resp.json()
    assert data["order_id"] == order_id
    assert data["status"] == "in_progress"
    assert data["product_id"] == "pack_20"
    assert data["target_count"] == 20
    assert data["language"] == "en"
    # Cost capture (#95): no spend recorded yet on a fresh order.
    assert data["llm_cost_usd"] is None
    assert data["search_cost_cents"] == 0
    # #103 F4c: refund_eligible now surfaces on the snapshot (False on a
    # healthy order; the field previously had zero readers anywhere).
    assert data["refund_eligible"] is False
    # #103 F5: actual_count is None until a pack is persisted.
    assert data["actual_count"] is None

    job = data["job"]
    assert job is not None
    # job starts as "queued"; order transitions to in_progress after the POST enqueue
    assert job["status"] == "queued"
    assert job["progress"] == 0
