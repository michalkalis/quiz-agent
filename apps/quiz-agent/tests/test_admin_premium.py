"""Guard test: POST /usage/{id}/premium stays admin-key-only (issue #60.9).

§10 of the plan corrected a false premise — setPremium is *already* protected by
an `X-Admin-Key`, and #60 must NOT downgrade it to the bearer middleware. This
test pins that guard at the HTTP layer so a future refactor can't quietly open
premium-granting to any authenticated client.
"""

from __future__ import annotations

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from fastapi import FastAPI
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.api.routes import misc as misc_routes
from app.rate_limit import limiter
from app.usage.tracker import UsageTracker

pytestmark = pytest.mark.asyncio

_ADMIN_KEY = "super-secret-admin-key"
_SUBJECT = "anon-premium-subject"


@pytest_asyncio.fixture
async def client(db_sessionmaker, monkeypatch):
    monkeypatch.setenv("ADMIN_API_KEY", _ADMIN_KEY)
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(misc_routes.router, prefix="/api/v1")
    app.state.usage_tracker = UsageTracker(db_sessionmaker, daily_limit=3)
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def test_premium_rejected_without_admin_key(client):
    resp = await client.post(f"/api/v1/usage/{_SUBJECT}/premium")
    assert resp.status_code == 401


async def test_premium_rejected_with_wrong_admin_key(client):
    resp = await client.post(
        f"/api/v1/usage/{_SUBJECT}/premium", headers={"X-Admin-Key": "wrong"}
    )
    assert resp.status_code == 401


async def test_premium_granted_with_correct_admin_key(client):
    resp = await client.post(
        f"/api/v1/usage/{_SUBJECT}/premium", headers={"X-Admin-Key": _ADMIN_KEY}
    )
    assert resp.status_code == 200
    assert resp.json() == {"user_id": _SUBJECT, "is_premium": True}

    # And it actually took effect.
    usage = await client.get(f"/api/v1/usage/{_SUBJECT}")
    assert usage.json()["is_premium"] is True
