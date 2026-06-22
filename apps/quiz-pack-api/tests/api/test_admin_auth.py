"""Admin-auth gate tests for /web and /api/v1 question routes (#65).

These pin the security property that the admin UI and the paid generation /
verify / review API are unreachable without a valid ADMIN_API_KEY:

- unset key          → 503 (fail closed, never silently open)
- absent / wrong key → 401
- valid key via X-Admin-Key header OR HTTP Basic → gate passes (not 401)

`get_settings` is overridden to inject the key, so no real Fly secret is
needed and the tests don't touch a DB. The acceptance route
`POST /api/v1/generate/advanced` is asserted only in the negative cases —
a valid key there would proceed into the body and fire a real gpt-4o call.
The positive (valid-key) path is proven on `GET /web/`, which makes no LLM
call. `{}` is a valid AdvancedGenerateRequest body (all fields default), so
the negative assertions are robust to FastAPI's dependency/body ordering.
"""

from __future__ import annotations

import base64
from typing import AsyncIterator

import httpx
import pytest_asyncio
from fastapi import FastAPI

from app.api.deps import get_settings
from app.api.routes import router as questions_router
from app.config import Settings
from app.web.routes import router as web_router


def _build_app(admin_api_key) -> FastAPI:
    app = FastAPI()
    app.include_router(web_router)
    app.include_router(questions_router)
    app.dependency_overrides[get_settings] = lambda: Settings(admin_api_key=admin_api_key)
    return app


def _basic(user: str, password: str) -> str:
    raw = f"{user}:{password}".encode("utf-8")
    return "Basic " + base64.b64encode(raw).decode("ascii")


@pytest_asyncio.fixture
async def client() -> AsyncIterator[httpx.AsyncClient]:
    """Client against an app whose admin key is 'testkey'.

    `raise_app_exceptions=False` so a body that blows up *after* the gate
    passes (the `/web` home template hits a Python 3.14 + Jinja2 LRUCache bug
    in this env) surfaces as a 500 response rather than propagating — the gate
    let it through, which is all the positive test asserts. The 401/503 gate
    responses are real FastAPI HTTPException responses, unaffected by this.
    """
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=_build_app("testkey"), raise_app_exceptions=False),
        base_url="http://test",
    ) as ac:
        yield ac


# --- negative: both acceptance routes 401 without a valid key ----------------


async def test_web_home_requires_key(client: httpx.AsyncClient) -> None:
    resp = await client.get("/web/")
    assert resp.status_code == 401


async def test_web_home_wrong_key(client: httpx.AsyncClient) -> None:
    resp = await client.get("/web/", headers={"X-Admin-Key": "nope"})
    assert resp.status_code == 401


async def test_generate_advanced_requires_key(client: httpx.AsyncClient) -> None:
    resp = await client.post("/api/v1/generate/advanced", json={})
    assert resp.status_code == 401


async def test_generate_advanced_wrong_key(client: httpx.AsyncClient) -> None:
    resp = await client.post(
        "/api/v1/generate/advanced", json={}, headers={"X-Admin-Key": "nope"}
    )
    assert resp.status_code == 401


# --- positive: a valid key passes the gate (proven on /web/, no paid call) ---


async def test_web_home_valid_header_key(client: httpx.AsyncClient) -> None:
    resp = await client.get("/web/", headers={"X-Admin-Key": "testkey"})
    assert resp.status_code not in (401, 503)  # gate let it through to the body


async def test_web_home_valid_basic_auth(client: httpx.AsyncClient) -> None:
    resp = await client.get("/web/", headers={"Authorization": _basic("admin", "testkey")})
    assert resp.status_code not in (401, 503)  # gate let it through to the body


# --- fail-closed: unset key → 503, never silently open -----------------------


async def test_unset_key_fails_closed() -> None:
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=_build_app(None)),
        base_url="http://test",
    ) as ac:
        resp = await ac.get("/web/", headers={"X-Admin-Key": "anything"})
    assert resp.status_code == 503
