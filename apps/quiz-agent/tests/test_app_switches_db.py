"""#207 task 207.18: app switches changed live through the DB, no restart.

Why these tests matter:
- Flipping a Fly secret restarts the only quiz-agent machine mid-quiz; the DB
  override exists so the founder can pause orders, force an update or show a
  notice without that. A write must therefore reach ``/app-config`` on the very
  next request, not after the 60 s cache.
- Every shipped build (1.0 and 1.1) reads ``/app-config`` at launch. With no
  override rows the response must be exactly the env-driven one it was before,
  and a typo in a minimum version must be refused at write time, because a
  served bad minimum would lock every installed build out.
- The read is on the launch path: a broken DB keeps the last good switches
  instead of failing the route or silently dropping a pause.
"""

from __future__ import annotations

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from app import app_switches
from app.api.routes import app_config as app_config_routes

pytestmark = pytest.mark.asyncio

KEY = "k"


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("ADMIN_API_KEY", KEY)
    for name in (
        "MIN_APP_VERSION_APP_STORE",
        "MIN_APP_VERSION_TESTFLIGHT",
        "PACK_ORDERS_ENABLED",
        "APP_NOTICE_SK",
        "APP_NOTICE_CS",
        "APP_NOTICE_EN",
    ):
        monkeypatch.delenv(name, raising=False)
    app_switches.reset_cache()
    yield
    app_switches.reset_cache()


def _client(sessionmaker) -> AsyncClient:
    app = FastAPI()
    app.include_router(app_config_routes.router, prefix="/api/v1")
    app.state.auth_sessionmaker = sessionmaker
    return AsyncClient(transport=ASGITransport(app=app), base_url="http://t")


async def _config(sessionmaker) -> dict:
    async with _client(sessionmaker) as c:
        resp = await c.get("/api/v1/app-config")
    assert resp.status_code == 200
    return resp.json()


async def _put(sessionmaker, body: dict, key: str = KEY):
    async with _client(sessionmaker) as c:
        return await c.put(
            "/api/v1/admin/app-switches", json=body, headers={"X-Admin-Key": key}
        )


async def test_no_rows_serves_exactly_the_env_switches(monkeypatch, db_sessionmaker):
    monkeypatch.setenv("MIN_APP_VERSION_APP_STORE", "1.0")
    monkeypatch.setenv("APP_NOTICE_EN", "Maintenance tonight.")

    body = await _config(db_sessionmaker)

    assert body["min_version_app_store"] == "1.0"
    assert body["min_version_testflight"] is None
    assert body["orders_enabled"] is True
    assert body["notice"] == {"sk": None, "cs": None, "en": "Maintenance tonight."}


async def test_a_write_is_served_on_the_next_request(db_sessionmaker):
    # Warm the 60 s cache first: the write must not wait for it to expire.
    assert (await _config(db_sessionmaker))["orders_enabled"] is True

    resp = await _put(
        db_sessionmaker,
        {"set": {"orders_enabled": False, "min_version_app_store": "1.1",
                 "notice_sk": "  Objednávky sú dnes pozastavené.  "}},
    )  # fmt: skip

    assert resp.status_code == 200, resp.text
    body = await _config(db_sessionmaker)
    assert body["orders_enabled"] is False
    assert body["min_version_app_store"] == "1.1"
    assert body["notice"] == {
        "sk": "Objednávky sú dnes pozastavené.",
        "cs": None,
        "en": None,
    }


async def test_override_beats_env_and_reset_returns_to_env(
    monkeypatch, db_sessionmaker
):
    monkeypatch.setenv("PACK_ORDERS_ENABLED", "false")
    monkeypatch.setenv("MIN_APP_VERSION_APP_STORE", "1.0")
    monkeypatch.setenv("APP_NOTICE_EN", "Old notice.")

    # Null/blank switches a value off even when env sets it.
    resp = await _put(
        db_sessionmaker,
        {
            "set": {
                "orders_enabled": True,
                "min_version_app_store": None,
                "notice_en": "",
            }
        },
    )
    assert resp.json()["effective"]["orders_enabled"] is True
    body = await _config(db_sessionmaker)
    assert (body["orders_enabled"], body["min_version_app_store"], body["notice"]) == (
        True,
        None,
        None,
    )

    resp = await _put(
        db_sessionmaker,
        {"reset": ["orders_enabled", "min_version_app_store", "notice_en"]},
    )
    assert resp.json()["overrides"] == {}
    body = await _config(db_sessionmaker)
    assert body["orders_enabled"] is False
    assert body["min_version_app_store"] == "1.0"
    assert body["notice"]["en"] == "Old notice."


@pytest.mark.parametrize(
    "change",
    [
        {"min_version_app_store": "v1.2"},
        {"min_version_testflight": "1.2-beta"},
        {"orders_enabled": "false"},  # a string, not a bool
        {"notice_en": "x" * 301},
        {"recommended_version_app_store": "latest"},
        {"maintenance_enabled": "true"},  # a string, not a bool
        {"maintenance_sk": "x" * 301},
        {"daily_challenge_enabled": True},  # not a DB switch
    ],
)
async def test_bad_values_are_refused_and_nothing_is_written(db_sessionmaker, change):
    resp = await _put(db_sessionmaker, {"set": {"orders_enabled": False, **change}})

    assert resp.status_code == 422
    # All or nothing: the valid orders change in the same request did not land.
    assert (await _config(db_sessionmaker))["orders_enabled"] is True


async def test_maintenance_and_nudge_switch_on_and_off_live(db_sessionmaker):
    """#214: maintenance blocks every current build, so turning it off must be
    as immediate as turning it on, and a blank message falls back to the app's
    own text instead of an empty screen."""
    await _put(
        db_sessionmaker,
        {"set": {"maintenance_enabled": True, "maintenance_en": " Back at 10:00. ",
                 "recommended_version_app_store": "1.2"}},
    )  # fmt: skip
    body = await _config(db_sessionmaker)
    assert body["maintenance_enabled"] is True
    assert body["maintenance_message"] == {
        "sk": None,
        "cs": None,
        "en": "Back at 10:00.",
    }
    assert body["recommended_version_app_store"] == "1.2"
    # The nudge must never turn into a forced update.
    assert body["min_version_app_store"] is None

    await _put(
        db_sessionmaker,
        {"set": {"maintenance_enabled": False}, "reset": ["maintenance_en"]},
    )
    body = await _config(db_sessionmaker)
    assert (body["maintenance_enabled"], body["maintenance_message"]) == (False, None)


async def test_admin_key_is_required(db_sessionmaker):
    resp = await _put(db_sessionmaker, {"set": {"orders_enabled": False}}, key="wrong")

    assert resp.status_code == 401
    assert (await _config(db_sessionmaker))["orders_enabled"] is True


async def test_a_broken_read_keeps_the_last_good_switches(db_sessionmaker, monkeypatch):
    await _put(db_sessionmaker, {"set": {"orders_enabled": False}})
    assert (await _config(db_sessionmaker))["orders_enabled"] is False

    # Cache expires, then the DB read fails: the pause must stay in force.
    monkeypatch.setattr(app_switches, "CACHE_SECONDS", 0.0)
    app_switches._cache = (0.0, app_switches._cache[1])

    async def _broken(_sessionmaker):
        raise RuntimeError("db down")

    monkeypatch.setattr(app_switches, "read_overrides", _broken)
    assert (await _config(db_sessionmaker))["orders_enabled"] is False
