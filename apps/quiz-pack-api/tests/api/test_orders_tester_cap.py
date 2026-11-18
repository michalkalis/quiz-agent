"""Tester weekly pack cap on POST /v1/orders.

TestFlight testers pay with Sandbox purchases, which are free to them while
every generated pack costs real money. The cap keeps a tester from ordering
an unbounded number of packs, without ever touching a paying customer
(Production purchases) or the founder's admin orders.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import httpx
import pytest
from app.db.models.order import GenerationOrder
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from tests.api.conftest import TEST_ADMIN_KEY, _bearer
from tests.storekit._chain_fixtures import JWSFactory

BEARER = _bearer("tester-account")


def _body(tx_id: str) -> dict:
    return {
        "transaction_id": tx_id,
        "product_id": "pack_20",
        "prompt": "Interesting facts about the solar system",
        "language": "en",
        "target_count": 20,
    }


async def _order(client, make_jws, tx_id, *, env="Sandbox", headers=None):
    jws = make_jws(payload_overrides={"transactionId": tx_id, "environment": env})
    return await client.post(
        "/v1/orders",
        json=_body(tx_id),
        headers={"X-StoreKit-JWS": jws, **BEARER, **(headers or {})},
    )


@pytest.mark.asyncio
async def test_tester_over_weekly_cap_is_refused_with_readable_date(
    client: httpx.AsyncClient, app_settings, make_jws: JWSFactory, test_session: AsyncSession
) -> None:
    app_settings.tester_weekly_pack_cap = 2
    for i in range(2):
        resp = await _order(client, make_jws, f"tx-cap-{i}")
        assert resp.status_code == 202, resp.text

    resp = await _order(client, make_jws, "tx-cap-over", headers={"Accept-Language": "sk-SK"})

    assert resp.status_code == 429
    # Shipped builds show `detail` verbatim, so it must be a Slovak sentence
    # telling the tester when they can order again (7 days after the oldest).
    oldest = min(
        (await test_session.execute(select(GenerationOrder.created_at))).scalars().all()
    )
    nxt = oldest + timedelta(days=7)
    assert resp.json()["detail"] == (
        "Týždenný limit testovacích balíkov je vyčerpaný. "
        f"Ďalší sa dá vytvoriť od {nxt.day}. {nxt.month}."
    )
    # No row for the refused order: nothing is generated, nothing is spent.
    test_session.expire_all()
    txs = (await test_session.execute(select(GenerationOrder.transaction_id))).scalars().all()
    assert "tx-cap-over" not in txs


@pytest.mark.asyncio
async def test_tester_can_order_again_once_oldest_order_ages_out(
    client: httpx.AsyncClient, app_settings, make_jws: JWSFactory, test_session: AsyncSession
) -> None:
    """The window is rolling, so a tester is not locked out until some fixed
    weekday; a burst of testing just spends the week's packs early."""
    app_settings.tester_weekly_pack_cap = 1
    assert (await _order(client, make_jws, "tx-old")).status_code == 202
    await test_session.execute(
        update(GenerationOrder)
        .where(GenerationOrder.transaction_id == "tx-old")
        .values(created_at=datetime.now(UTC) - timedelta(days=8))
    )
    await test_session.commit()

    assert (await _order(client, make_jws, "tx-new")).status_code == 202


@pytest.mark.asyncio
async def test_paying_customer_is_never_capped(
    client: httpx.AsyncClient, app_settings, make_jws: JWSFactory
) -> None:
    app_settings.tester_weekly_pack_cap = 1
    for i in range(3):
        resp = await _order(client, make_jws, f"tx-prod-{i}", env="Production")
        assert resp.status_code == 202, resp.text


@pytest.mark.asyncio
async def test_founder_admin_orders_are_never_capped(
    client: httpx.AsyncClient, app_settings
) -> None:
    app_settings.tester_weekly_pack_cap = 1
    for i in range(3):
        resp = await client.post(
            "/v1/orders",
            json=_body(f"admin-cap-{i}"),
            headers={"X-Admin-Key": TEST_ADMIN_KEY, **BEARER},
        )
        assert resp.status_code == 202, resp.text


@pytest.mark.asyncio
async def test_replay_of_existing_order_is_not_refused_by_cap(
    client: httpx.AsyncClient, app_settings, make_jws: JWSFactory
) -> None:
    """A lost-response retry of an order already accepted must still get its
    200, or the app would show an error for a pack that is being made."""
    app_settings.tester_weekly_pack_cap = 1
    assert (await _order(client, make_jws, "tx-replay")).status_code == 202
    assert (await _order(client, make_jws, "tx-replay")).status_code == 200
