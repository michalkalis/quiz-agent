"""#95 Session 1 — order-API access rules.

Why these tests exist: the custom-pack client plan hinges on three auth
guarantees the Phase-1 API didn't have —

1. the founder can create orders with the admin key alone (payments deferred),
2. orders link to the quiz-agent account (bearer JWT) so "My packs" works,
3. reads are no longer anonymous (any-order enumeration was the Phase-1 hole).

Reuses the fixtures from test_orders (minimal app, test chain, DB overrides).
"""

from __future__ import annotations

import uuid

import httpx
import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from quiz_shared.auth.tokens import TokenService

from app.db.models.order import GenerationOrder
from tests.api.conftest import TEST_ADMIN_KEY, TEST_JWT_SECRET
from tests.api.test_orders import _valid_body

ADMIN = {"X-Admin-Key": TEST_ADMIN_KEY}


def _bearer(subject: str) -> dict[str, str]:
    """Mint a real quiz-agent-shaped access token for `subject`."""
    service = TokenService(
        secret=TEST_JWT_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
    )
    return {"Authorization": f"Bearer {service.create_access_token(subject)}"}


def _admin_body(tx_suffix: str = "1", product_id: str = "pack_30") -> dict:
    return _valid_body(tx_id=f"admin-{tx_suffix}", product_id=product_id)


# ---------------------------------------------------------------------------
# POST /v1/orders — admin path
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_admin_create_202_no_jws(
    client: httpx.AsyncClient, test_session: AsyncSession
) -> None:
    """Admin key alone creates an order — the founder path needs no StoreKit."""
    resp = await client.post("/v1/orders", json=_admin_body(), headers=ADMIN)
    assert resp.status_code == 202, resp.text

    test_session.expire_all()
    order_id = uuid.UUID(resp.json()["order_id"])
    order = (
        await test_session.execute(
            select(GenerationOrder).where(GenerationOrder.id == order_id)
        )
    ).scalars().first()
    assert order is not None
    assert order.target_count == 30  # server-derived for pack_30
    assert order.user_id is None  # no bearer sent


@pytest.mark.asyncio
async def test_admin_create_links_bearer_account(
    client: httpx.AsyncClient, test_session: AsyncSession
) -> None:
    """A bearer JWT alongside the admin key sets user_id — without this the
    order is orphaned and never shows in `GET /v1/orders` (My packs)."""
    resp = await client.post(
        "/v1/orders",
        json=_admin_body("linked"),
        headers={**ADMIN, **_bearer("acct-123")},
    )
    assert resp.status_code == 202, resp.text

    test_session.expire_all()
    order_id = uuid.UUID(resp.json()["order_id"])
    order = (
        await test_session.execute(
            select(GenerationOrder).where(GenerationOrder.id == order_id)
        )
    ).scalars().first()
    assert order is not None and order.user_id == "acct-123"


@pytest.mark.asyncio
async def test_admin_create_wrong_key_401(client: httpx.AsyncClient) -> None:
    resp = await client.post(
        "/v1/orders", json=_admin_body(), headers={"X-Admin-Key": "wrong"}
    )
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_admin_create_requires_admin_tx_prefix_400(
    client: httpx.AsyncClient,
) -> None:
    """Admin orders must not claim Apple-shaped transaction ids — a founder
    order squatting a numeric tx id would block a future real purchase's
    idempotency slot."""
    resp = await client.post(
        "/v1/orders", json=_valid_body(tx_id="1000000999999999"), headers=ADMIN
    )
    assert resp.status_code == 400
    assert "admin-" in resp.json()["detail"]


@pytest.mark.asyncio
async def test_create_invalid_bearer_401(client: httpx.AsyncClient) -> None:
    """A present-but-invalid bearer is rejected, not silently dropped —
    silently dropping it would orphan the order without anyone noticing."""
    resp = await client.post(
        "/v1/orders",
        json=_admin_body("badtoken"),
        headers={**ADMIN, "Authorization": "Bearer not-a-jwt"},
    )
    assert resp.status_code == 401


# ---------------------------------------------------------------------------
# GET /v1/orders/{id} — read authorization (#95 closes the Phase-1 hole)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_order_unauthenticated_401(client: httpx.AsyncClient) -> None:
    """Anonymous reads are gone — auth fails before existence is revealed."""
    resp = await client.get(f"/v1/orders/{uuid.uuid4()}")
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_get_order_owner_and_stranger(client: httpx.AsyncClient) -> None:
    """The owner's bearer reads the order; another account gets 403."""
    post = await client.post(
        "/v1/orders",
        json=_admin_body("owner"),
        headers={**ADMIN, **_bearer("owner-1")},
    )
    order_id = post.json()["order_id"]

    owner_resp = await client.get(f"/v1/orders/{order_id}", headers=_bearer("owner-1"))
    assert owner_resp.status_code == 200, owner_resp.text

    stranger_resp = await client.get(
        f"/v1/orders/{order_id}", headers=_bearer("someone-else")
    )
    assert stranger_resp.status_code == 403


# ---------------------------------------------------------------------------
# GET /v1/orders — list my orders
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_orders_requires_bearer_401(client: httpx.AsyncClient) -> None:
    resp = await client.get("/v1/orders")
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_list_orders_only_own_newest_first(client: httpx.AsyncClient) -> None:
    """The list is scoped to the caller's account and ordered newest-first —
    the contract OrderPackView/My-packs (Sessions 2–3) is built on."""
    for suffix, subject in (("a", "list-user"), ("b", "list-user"), ("c", "other")):
        resp = await client.post(
            "/v1/orders",
            json=_admin_body(f"list-{suffix}"),
            headers={**ADMIN, **_bearer(subject)},
        )
        assert resp.status_code == 202, resp.text

    resp = await client.get("/v1/orders", headers=_bearer("list-user"))
    assert resp.status_code == 200, resp.text
    orders = resp.json()["orders"]
    assert len(orders) == 2
    created = [o["created_at"] for o in orders]
    assert created == sorted(created, reverse=True)


@pytest.mark.asyncio
async def test_list_orders_empty_for_unknown_account(
    client: httpx.AsyncClient,
) -> None:
    resp = await client.get("/v1/orders", headers=_bearer("nobody"))
    assert resp.status_code == 200
    assert resp.json()["orders"] == []
