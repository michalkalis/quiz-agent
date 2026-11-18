"""#205 beta preview of the daily challenge.

Why these tests matter: every App Store build since 1.1 already contains the
daily challenge card. The founder wants to test it in Trubbo Beta first, so
while ``DAILY_CHALLENGE_ENABLED`` is off, only builds at or above the DB switch
``daily_challenge_beta_min_build`` may see it, and no store build (lower build
number, or no recognizable User-Agent) may ever get the card or the endpoints.
"""

from __future__ import annotations

import pytest
from app import app_switches
from app.api.routes import app_config as app_config_routes
from app.daily_challenge.gate import build_from_user_agent
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

pytestmark = pytest.mark.asyncio

BETA_UA = "Hangs/89 CFNetwork/3826.500.111 Darwin/25.0.0"
STORE_UA = "Hangs/86 CFNetwork/3826.500.111 Darwin/25.0.0"


@pytest.mark.parametrize(
    "ua, build",
    [
        (BETA_UA, 89),
        ("Trubbo%20Beta/90 CFNetwork/1568 Darwin/24.0.0", 90),
        ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", None),
        ("curl/8.7.1", None),
        ("", None),
        (None, None),
    ],
)
async def test_build_number_is_read_only_from_a_cfnetwork_user_agent(ua, build):
    assert build_from_user_agent(ua) == build


@pytest.fixture
def switches(monkeypatch):
    """Serve DB overrides without a DB; env daily switch off (prod today)."""
    monkeypatch.setenv("DAILY_CHALLENGE_ENABLED", "false")
    overrides: dict[str, str | None] = {}

    async def fake_cached(_sessionmaker):
        return overrides

    monkeypatch.setattr(app_switches, "cached_overrides", fake_cached)
    return overrides


async def _daily_flag(user_agent: str | None) -> tuple[bool, str | None]:
    config_app = FastAPI()
    config_app.include_router(app_config_routes.router, prefix="/api/v1")
    headers = {"User-Agent": user_agent} if user_agent else {}
    transport = ASGITransport(app=config_app)
    async with AsyncClient(transport=transport, base_url="http://t") as c:
        resp = await c.get("/api/v1/app-config", headers=headers)
    return resp.json()["daily_challenge_enabled"], resp.headers.get("vary")


async def test_beta_builds_see_the_card_store_builds_do_not(switches):
    switches["daily_challenge_beta_min_build"] = "87"

    assert (await _daily_flag(BETA_UA))[0] is True
    assert (await _daily_flag("Hangs/87 CFNetwork/1 Darwin/1"))[0] is True
    assert (await _daily_flag(STORE_UA))[0] is False
    assert (await _daily_flag(None))[0] is False


async def test_without_the_switch_nobody_sees_it(switches):
    assert (await _daily_flag(BETA_UA))[0] is False


async def test_env_switch_on_shows_it_to_every_build(switches, monkeypatch):
    monkeypatch.setenv("DAILY_CHALLENGE_ENABLED", "true")
    assert (await _daily_flag(STORE_UA))[0] is True


async def test_app_config_varies_by_user_agent(switches):
    # A shared cache must not hand a beta body to a store build.
    _, vary = await _daily_flag(BETA_UA)
    assert vary == "User-Agent"


async def test_switch_value_must_be_a_build_number():
    assert app_switches.encode("daily_challenge_beta_min_build", " 87 ") == "87"
    assert app_switches.encode("daily_challenge_beta_min_build", None) is None
    with pytest.raises(ValueError):
        app_switches.encode("daily_challenge_beta_min_build", "1.2")
