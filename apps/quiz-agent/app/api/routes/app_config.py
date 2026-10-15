"""Remote app switches for shipped iOS builds (#193 task 193.9 — beta hardening).

``GET /app-config`` lets a public build be steered without an app release:
force builds below a minimum version to update, pause custom-pack ordering,
or show a short notice. Values come from env (``app.config.Settings``), so a
Fly secret/env change flips them on the running deploy. The voice-settings test
(#204.9) is the exception: it lives in the DB so the weekly job can change it.

Public and unauthenticated: the client calls it at launch before any token
exists, and treats any failure as "no switches set" (fail open), so this route
must never be the reason a build cannot play.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Depends, Response
from pydantic import BaseModel

from ...config import get_settings
from ...voice_experiment.served import voice_experiment_config
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
    notice = AppNotice(
        sk=settings.app_notice_sk,
        cs=settings.app_notice_cs,
        en=settings.app_notice_en,
    )
    response.headers["Cache-Control"] = CACHE_CONTROL
    return AppConfigResponse(
        min_version_app_store=settings.min_app_version_app_store,
        min_version_testflight=settings.min_app_version_testflight,
        orders_enabled=settings.pack_orders_enabled,
        daily_challenge_enabled=settings.daily_challenge_enabled,
        notice=notice if (notice.sk or notice.cs or notice.en) else None,
        voice_experiment=await voice_experiment_config(sessionmaker),
    )
