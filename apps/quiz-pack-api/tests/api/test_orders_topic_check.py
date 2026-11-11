"""#233: `POST /v1/orders/topic-check` — the app's gate before payment.

DB-free on purpose: the check touches no order rows, so it must work even
when nothing has been bought yet.
"""

from __future__ import annotations

import httpx
import pytest
from app import topic_check
from app.api.v1.orders import router as orders_router
from app.config import Settings, get_settings
from app.rate_limit import limiter
from fastapi import FastAPI

from tests.api.conftest import TEST_JWT_SECRET, _bearer


@pytest.fixture
def client():
    app = FastAPI()
    app.state.limiter = limiter
    app.include_router(orders_router)
    app.dependency_overrides[get_settings] = lambda: Settings(
        auth_jwt_secret=TEST_JWT_SECRET
    )
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    )


@pytest.mark.asyncio
async def test_returns_the_verdict(client, monkeypatch):
    seen = []

    async def fake_check(prompt):
        seen.append(prompt)
        return "blocked", False

    monkeypatch.setattr(topic_check, "check_topic", fake_check)
    async with client:
        resp = await client.post(
            "/v1/orders/topic-check",
            json={"prompt": "  how to make a bomb  ", "language": "en"},
            headers=_bearer("acct-1"),
        )
    assert resp.status_code == 200
    assert resp.json() == {"verdict": "blocked"}
    assert seen == ["how to make a bomb"]


@pytest.mark.asyncio
async def test_requires_sign_in(client):
    # Same gate as ordering: an anonymous caller could otherwise spend model
    # calls for free.
    async with client:
        resp = await client.post(
            "/v1/orders/topic-check", json={"prompt": "dogs", "language": "en"}
        )
    assert resp.status_code == 401


@pytest.mark.asyncio
@pytest.mark.parametrize("prompt", ["   ", "a" * 1001])
async def test_same_length_bounds_as_ordering(client, prompt, monkeypatch):
    async def never(prompt):
        raise AssertionError("model must not be called")

    monkeypatch.setattr(topic_check, "check_topic", never)
    async with client:
        resp = await client.post(
            "/v1/orders/topic-check",
            json={"prompt": prompt, "language": "en"},
            headers=_bearer("acct-1"),
        )
    assert resp.status_code == 422
