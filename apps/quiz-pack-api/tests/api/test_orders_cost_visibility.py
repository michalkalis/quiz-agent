"""#217 task 217.3 — the order API never tells a pack owner what generation cost us.

Why: the order snapshot carries our measured spend (LLM usage, search, the
job total). Before the App Store launch that went to every pack owner: a
buyer of a €8.99 pack could read our cost of goods straight off the JSON. The
admin key (founder / ops) still needs the numbers to watch margins.

The fields stay in the response with neutral values (None / 0) instead of
being dropped: shipped iOS builds decode `search_cost_cents` and
`job.total_cost_cents` as non-optional ints, and the CI OpenAPI compat gate
fails a PR that removes a response field.

Reuses the fixtures from test_orders (minimal app, test chain, DB overrides).
"""

from __future__ import annotations

from decimal import Decimal

import httpx
import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models.job import GenerationJob
from app.db.models.order import GenerationOrder
from tests.api.conftest import TEST_ADMIN_KEY, _bearer

OWNER = "cost-owner"
ADMIN = {"X-Admin-Key": TEST_ADMIN_KEY}
# The budget cut-off text quotes the spend (app.order_budget), so the job
# error is a cost leak of its own.
BUDGET_ERROR = "order spend ceiling reached: 523 cents already spent across 3 attempt(s)"


async def _seed_costed_order(session: AsyncSession) -> GenerationOrder:
    """A failed order with real spend recorded, as the worker leaves it."""
    order = GenerationOrder(
        user_id=OWNER,
        transaction_id="admin-cost-visibility",
        product_id="pack_30",
        prompt="Famous bridges of Slovakia",
        target_count=30,
        language="en",
        status="failed",
        llm_cost_usd=Decimal("4.230000"),
        search_cost_cents=37,
    )
    session.add(order)
    await session.flush()
    job = GenerationJob(
        order_id=order.id,
        status="failed",
        total_cost_cents=460,
        cumulative_cost_cents=523,
        error=BUDGET_ERROR,
    )
    session.add(job)
    await session.flush()
    order.job_id = job.id
    await session.commit()
    return order


def _assert_costs_hidden(snapshot: dict) -> None:
    assert snapshot["llm_cost_usd"] is None
    assert snapshot["search_cost_cents"] == 0
    assert snapshot["job"]["total_cost_cents"] == 0
    assert snapshot["job"]["error"] is None


def _assert_costs_shown(snapshot: dict) -> None:
    assert Decimal(snapshot["llm_cost_usd"]) == Decimal("4.23")
    assert snapshot["search_cost_cents"] == 37
    assert snapshot["job"]["total_cost_cents"] == 460
    assert snapshot["job"]["error"] == BUDGET_ERROR


@pytest.mark.asyncio
async def test_owner_cannot_read_generation_cost(
    client: httpx.AsyncClient, test_session: AsyncSession
) -> None:
    """The buyer reads their own order (detail and list) without our COGS,
    while the rest of the snapshot is still theirs to see."""
    order = await _seed_costed_order(test_session)

    detail = await client.get(f"/v1/orders/{order.id}", headers=_bearer(OWNER))
    assert detail.status_code == 200, detail.text
    _assert_costs_hidden(detail.json())
    assert detail.json()["status"] == "failed"

    listed = await client.get("/v1/orders", headers=_bearer(OWNER))
    assert listed.status_code == 200, listed.text
    [snapshot] = listed.json()["orders"]
    _assert_costs_hidden(snapshot)


@pytest.mark.asyncio
async def test_admin_still_reads_generation_cost(
    client: httpx.AsyncClient, test_session: AsyncSession
) -> None:
    """The founder watches per-pack margins through the admin key; hiding the
    numbers from players must not blind ops."""
    order = await _seed_costed_order(test_session)

    detail = await client.get(f"/v1/orders/{order.id}", headers=ADMIN)
    assert detail.status_code == 200, detail.text
    _assert_costs_shown(detail.json())

    listed = await client.get("/v1/orders", headers={**ADMIN, **_bearer(OWNER)})
    assert listed.status_code == 200, listed.text
    [snapshot] = listed.json()["orders"]
    _assert_costs_shown(snapshot)


@pytest.mark.asyncio
async def test_wrong_admin_key_on_list_hides_cost_without_breaking_the_list(
    client: httpx.AsyncClient, test_session: AsyncSession
) -> None:
    """On the list the bearer is the credential; the admin key is only an
    extra. A wrong key must neither unlock the costs nor 401 the owner's list."""
    await _seed_costed_order(test_session)

    listed = await client.get(
        "/v1/orders", headers={"X-Admin-Key": "not-the-key", **_bearer(OWNER)}
    )
    assert listed.status_code == 200, listed.text
    [snapshot] = listed.json()["orders"]
    _assert_costs_hidden(snapshot)
