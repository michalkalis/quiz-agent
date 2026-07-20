"""GET /api/v1/health must actually probe the DB (backend arch review
2026-07-18, misc.py:128): it gates Fly's rollback, so a deploy against an
unreachable Postgres has to fail the check, not return a static 200.
"""

from __future__ import annotations

import pytest
import pytest_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from app.api.routes import misc as misc_routes

pytestmark = pytest.mark.asyncio


def _make_app(sessionmaker) -> FastAPI:
    app = FastAPI()
    app.include_router(misc_routes.router, prefix="/api/v1")
    app.state.auth_sessionmaker = sessionmaker
    return app


@pytest_asyncio.fixture
async def client_with_db(db_sessionmaker):
    app = _make_app(db_sessionmaker)
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def test_health_ok_when_db_reachable(client_with_db):
    resp = await client_with_db.get("/api/v1/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "healthy"
    assert body["service"] == "quiz-agent"
    assert "timestamp" in body


async def test_health_503_when_db_unreachable():
    """A sessionmaker bound to a dead engine must fail the probe with a
    fail-loud 503, not silently pass the rollback gate."""
    from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

    from app.db.engine import build_engine

    # Port 1 is never a live Postgres — the connect attempt fails fast.
    dead_engine = build_engine("postgresql+asyncpg://u:p@127.0.0.1:1/db")
    dead_sessionmaker = async_sessionmaker(dead_engine, class_=AsyncSession)

    app = _make_app(dead_sessionmaker)
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        resp = await c.get("/api/v1/health")

    assert resp.status_code == 503
    await dead_engine.dispose()


async def test_health_ok_when_no_sessionmaker_configured():
    """Auth disabled (no DATABASE_URL) must not turn health-check into a hard
    dependency — the route already tolerates a None sessionmaker elsewhere."""
    app = _make_app(None)
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        resp = await c.get("/api/v1/health")

    assert resp.status_code == 200
