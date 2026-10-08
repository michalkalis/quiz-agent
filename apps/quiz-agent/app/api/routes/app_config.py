"""Remote app switches for shipped iOS builds (#193 task 193.9 — beta hardening).

``GET /app-config`` lets a public build be steered without an app release:
force builds below a minimum version to update, pause custom-pack ordering,
or show a short notice. Values come from env (``app.config.Settings``), so a
Fly secret/env change flips them on the running deploy.

Public and unauthenticated: the client calls it at launch before any token
exists, and treats any failure as "no switches set" (fail open), so this route
must never be the reason a build cannot play.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Response
from pydantic import BaseModel

from ...config import get_settings

router = APIRouter()

# Short enough that a flipped switch reaches clients within a minute, long
# enough that a launch + foreground in quick succession share one fetch.
CACHE_CONTROL = "public, max-age=60"


class AppNotice(BaseModel):
    """One notice in each UI language; the client falls back to ``en``."""

    sk: Optional[str] = None
    cs: Optional[str] = None
    en: Optional[str] = None


class AppConfigResponse(BaseModel):
    """Switches the client applies. ``None`` minimum = no forced update."""

    min_version_app_store: Optional[str] = None
    min_version_testflight: Optional[str] = None
    orders_enabled: bool = True
    notice: Optional[AppNotice] = None


@router.get("/app-config", response_model=AppConfigResponse)
async def get_app_config(response: Response) -> AppConfigResponse:
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
        notice=notice if (notice.sk or notice.cs or notice.en) else None,
    )
