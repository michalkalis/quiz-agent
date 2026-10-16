"""Remote app switches for shipped iOS builds (#193 task 193.9 — beta hardening).

``GET /app-config`` lets a public build be steered without an app release:
force builds below a minimum version to update, pause custom-pack ordering,
or show a short notice. Each switch has an env default (``app.config.Settings``)
and a DB override (``app.app_switches``, #207 task 207.18) that the founder or
agent changes with ``PUT /admin/app-switches`` without restarting the machine.
The voice-settings test (#204.9) lives in the DB too, for its weekly job.

Public and unauthenticated: the client calls it at launch before any token
exists, and treats any failure as "no switches set" (fail open), so this route
must never be the reason a build cannot play.
"""

from __future__ import annotations

from typing import Any, Optional

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, Field

from ... import app_switches
from ...config import get_settings
from ...voice_experiment.served import voice_experiment_config
from ..admin import verify_admin_key
from ..deps import get_auth_sessionmaker

router = APIRouter()

# Short enough that a flipped switch reaches clients within a minute, long
# enough that a launch + foreground in quick succession share one fetch.
CACHE_CONTROL = "public, max-age=60"


class AppNotice(BaseModel):
    """One notice in each UI language; the client falls back to ``en``."""

    sk: Optional[str] = None
    cs: Optional[str] = None
    en: Optional[str] = None


class VoiceExperimentArmConfig(BaseModel):
    """How the app sets one voice setting on one route group."""

    status: str  # running | winner_on | off
    p_on: float
    generation: int


class AppConfigResponse(BaseModel):
    """Switches the client applies. ``None`` minimum = no forced update."""

    min_version_app_store: Optional[str] = None
    min_version_testflight: Optional[str] = None
    orders_enabled: bool = True
    # #205: show the daily challenge card on Home.
    daily_challenge_enabled: bool = False
    notice: Optional[AppNotice] = None
    # #204.9: the voice-settings test, {flag: {route_group: arm}}. Null when
    # there is no DB or the read fails; the app then uses its manual switches.
    voice_experiment: Optional[dict[str, dict[str, VoiceExperimentArmConfig]]] = None


@router.get("/app-config", response_model=AppConfigResponse)
async def get_app_config(
    response: Response, sessionmaker=Depends(get_auth_sessionmaker)
) -> AppConfigResponse:
    settings = get_settings()
    switches = app_switches.effective(
        settings, await app_switches.cached_overrides(sessionmaker)
    )
    notice = AppNotice(
        sk=switches["notice_sk"],
        cs=switches["notice_cs"],
        en=switches["notice_en"],
    )
    response.headers["Cache-Control"] = CACHE_CONTROL
    return AppConfigResponse(
        min_version_app_store=switches["min_version_app_store"],
        min_version_testflight=switches["min_version_testflight"],
        orders_enabled=switches["orders_enabled"],
        daily_challenge_enabled=settings.daily_challenge_enabled,
        notice=notice if (notice.sk or notice.cs or notice.en) else None,
        voice_experiment=await voice_experiment_config(sessionmaker),
    )


class AppSwitchesUpdate(BaseModel):
    """``set``: switch → new value (``null``/blank = off: no minimum, no
    notice). ``reset``: switches that go back to their env value."""

    set: dict[str, Any] = Field(default_factory=dict)
    reset: list[str] = Field(default_factory=list)


async def _switches_state(sessionmaker) -> dict[str, Any]:
    settings = get_settings()
    overrides = await app_switches.read_overrides(sessionmaker)
    return {
        "effective": app_switches.effective(settings, overrides),
        "overrides": overrides,
        "env": app_switches.env_values(settings),
    }


@router.get("/admin/app-switches")
async def get_app_switches(
    _: str = Depends(verify_admin_key),
    sessionmaker=Depends(get_auth_sessionmaker),
) -> dict[str, Any]:
    """What ``/app-config`` serves, the DB overrides and the env defaults."""
    if sessionmaker is None:
        raise HTTPException(status_code=503, detail="Database not configured")
    return await _switches_state(sessionmaker)


@router.put("/admin/app-switches")
async def put_app_switches(
    body: AppSwitchesUpdate,
    _: str = Depends(verify_admin_key),
    sessionmaker=Depends(get_auth_sessionmaker),
) -> dict[str, Any]:
    """Change switches live (no restart); served by ``/app-config`` at once."""
    if sessionmaker is None:
        raise HTTPException(status_code=503, detail="Database not configured")
    if overlap := set(body.set) & set(body.reset):
        raise HTTPException(
            status_code=422, detail=f"both set and reset: {sorted(overlap)}"
        )
    try:
        await app_switches.write(sessionmaker, body.set, body.reset)
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))
    return await _switches_state(sessionmaker)
