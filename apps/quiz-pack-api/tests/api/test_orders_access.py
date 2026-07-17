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

from app.db.models.order import GenerationOrder
from tests.api.conftest import TEST_ADMIN_KEY, _bearer
from tests.api.test_orders import _valid_body

ADMIN = {"X-Admin-Key": TEST_ADMIN_KEY}


def _admin_body(tx_suffix: str = "1", product_id: str = "pack_30") -> dict:
    return _valid_body(tx_id=f"admin-{tx_suffix}", product_id=product_id)


# ---------------------------------------------------------------------------
# POST /v1/orders — admin path
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_admin_create_without_bearer_401(client: httpx.AsyncClient) -> None:
    """#103 F3: the admin key alone is no longer enough — a bearer-less order
    would write user_id=NULL, orphaning the generated pack (unplayable via
    quiz-agent's ownership check, unlistable in `GET /v1/orders`, LLM cost
    already spent). The bearer is now mandatory alongside the admin key."""
    resp = await client.post("/v1/orders", json=_admin_body(), headers=ADMIN)
    assert resp.status_code == 401, resp.text


@pytest.mark.asyncio
async def test_admin_create_with_bearer_202(
    client: httpx.AsyncClient, test_session: AsyncSession
) -> None:
    """Admin key + bearer creates an order — the founder path needs no
    StoreKit, but still needs an account to own the pack (#103 F3)."""
    resp = await client.post(
        "/v1/orders",
        json=_admin_body(),
        headers={**ADMIN, **_bearer("founder-1")},
    )
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
    assert order.user_id == "founder-1"


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
    """Bearer present so the 401 is genuinely the wrong-admin-key check, not
    the (also-401) missing-bearer gate (#103 F3)."""
    resp = await client.post(
        "/v1/orders",
        json=_admin_body(),
        headers={"X-Admin-Key": "wrong", **_bearer("acct-1")},
    )
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_admin_create_requires_admin_tx_prefix_400(
    client: httpx.AsyncClient,
) -> None:
    """Admin orders must not claim Apple-shaped transaction ids — a founder
    order squatting a numeric tx id would block a future real purchase's
    idempotency slot. Bearer included (#103 F3 mandatory) so this 400 isn't
    masked by the earlier missing-bearer 401."""
    resp = await client.post(
        "/v1/orders",
        json=_valid_body(tx_id="1000000999999999"),
        headers={**ADMIN, **_bearer("acct-1")},
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
