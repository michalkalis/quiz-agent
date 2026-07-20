"""Canonical vs deprecated orders mounts must serve identically.

Backend arch review 2026-07-18: orders mounted at bare `/v1/orders` while the
rest of the API uses `/api/v1`. `/api/v1/orders` is now canonical; the bare
mount stays because deployed TestFlight iOS clients hard-code it — breaking
it is forbidden until the iOS client switches over (tracked followup). Both
mounts include the SAME router object, so per-route drift is structurally
impossible; what these tests pin is the mounting itself: (1) both prefixes
are live and answer identically (removing either mount line turns the
assertion into a 404), (2) OpenAPI advertises only the canonical paths, so
new clients are steered away from the deprecated prefix.
"""

from __future__ import annotations

import httpx
import pytest

from app.main import app


@pytest.mark.asyncio
async def test_both_mounts_live_and_answer_identically():
    """GET orders without a bearer needs no DB/Redis: routing + auth dep only.

    401 (not 404) proves the mount exists and reached the real endpoint;
    identical status + body across prefixes proves the alias serves the same
    handler, not a lookalike.
    """
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        canonical = await client.get("/api/v1/orders")
        alias = await client.get("/v1/orders")

    assert canonical.status_code == 401, "canonical /api/v1/orders mount missing"
    assert alias.status_code == 401, (
        "deprecated /v1/orders mount disappeared — deployed TestFlight iOS "
        "clients hard-code it and would 404 on every order"
    )
    assert alias.json() == canonical.json()


def test_openapi_advertises_only_canonical_orders_paths():
    orders_paths = [p for p in app.openapi()["paths"] if "/v1/orders" in p]
    assert any(p.startswith("/api/v1/orders") for p in orders_paths)
    assert not any(
        p.startswith("/v1/orders") for p in orders_paths
    ), "deprecated alias must stay out of the spec (kept only for old clients)"
