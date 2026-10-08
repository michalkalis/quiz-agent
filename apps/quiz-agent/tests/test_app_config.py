"""``GET /api/v1/app-config`` — remote switches for shipped builds (#193 task 193.9).

Why these tests matter: every public build blocks play when it is below the
served minimum version. So the defaults must be fully permissive (a deploy
that forgets the env must not lock anyone out), a malformed minimum must be
dropped rather than served, and every switch must come from env so the
founder can flip it with a Fly secret instead of shipping code.
"""

from __future__ import annotations

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from app.api.routes import app_config as app_config_routes

pytestmark = pytest.mark.asyncio

_ENV_VARS = (
    "MIN_APP_VERSION_APP_STORE",
    "MIN_APP_VERSION_TESTFLIGHT",
    "PACK_ORDERS_ENABLED",
    "APP_NOTICE_SK",
    "APP_NOTICE_CS",
    "APP_NOTICE_EN",
)


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for name in _ENV_VARS:
        monkeypatch.delenv(name, raising=False)


async def _get_config() -> tuple[int, dict, str | None]:
    app = FastAPI()
    app.include_router(app_config_routes.router, prefix="/api/v1")
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        resp = await client.get("/api/v1/app-config")
    return resp.status_code, resp.json(), resp.headers.get("cache-control")


async def test_defaults_never_block_or_hide_anything():
    status, body, cache_control = await _get_config()

    assert status == 200
    assert body == {
        "min_version_app_store": None,
        "min_version_testflight": None,
        "orders_enabled": True,
        "notice": None,
    }
    # Public and cacheable: hit at every launch/foreground, no per-user data.
    assert cache_control == "public, max-age=60"


async def test_switches_come_from_env(monkeypatch):
    monkeypatch.setenv("MIN_APP_VERSION_APP_STORE", "1.2")
    monkeypatch.setenv("MIN_APP_VERSION_TESTFLIGHT", "1.3.1")
    monkeypatch.setenv("PACK_ORDERS_ENABLED", "false")
    monkeypatch.setenv("APP_NOTICE_SK", "Dnes večer krátka údržba.")
    monkeypatch.setenv("APP_NOTICE_EN", "Short maintenance tonight.")

    _, body, _ = await _get_config()

    assert body["min_version_app_store"] == "1.2"
    assert body["min_version_testflight"] == "1.3.1"
    assert body["orders_enabled"] is False
    assert body["notice"] == {
        "sk": "Dnes večer krátka údržba.",
        "cs": None,
        "en": "Short maintenance tonight.",
    }


@pytest.mark.parametrize("raw", ["", "  ", "v1.2", "1.2-beta", "latest", "1..2"])
async def test_malformed_min_version_is_dropped_not_served(monkeypatch, raw):
    """A typo in the secret must disable the gate, never lock every build out."""
    monkeypatch.setenv("MIN_APP_VERSION_APP_STORE", raw)

    _, body, _ = await _get_config()

    assert body["min_version_app_store"] is None


async def test_blank_notice_texts_mean_no_notice(monkeypatch):
    """Clearing a notice by setting it to whitespace must hide it, not show an empty banner."""
    monkeypatch.setenv("APP_NOTICE_SK", "   ")
    monkeypatch.setenv("APP_NOTICE_EN", "")

    _, body, _ = await _get_config()

    assert body["notice"] is None
