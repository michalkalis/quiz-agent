"""Admin view of provider credit balances (#193) and ops health (#207)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request

from ...config import get_settings
from ...monitoring.ops_watch import Reading, watch
from ...monitoring.provider_balances import ProviderBalance, fetch_provider_balances
from ...usage.ai_grading_cap import ai_grading_stats
from ..admin import verify_admin_key
from ..deps import get_usage_caps

router = APIRouter()


@router.get("/admin/provider-balances", response_model=list[ProviderBalance])
async def provider_balances(
    _: str = Depends(verify_admin_key),
) -> list[ProviderBalance]:
    """Live account balance per provider; a provider whose API fails is
    `status="error"`, never a 500."""
    return await fetch_provider_balances(get_settings())


@router.get("/admin/ops-health", response_model=list[Reading])
async def ops_health(
    request: Request, _: str = Depends(verify_admin_key)
) -> list[Reading]:
    """#207: the ops watch's last readings (disk, memory, DB connections,
    response time) with their alarm thresholds; empty until its first run.
    #218.7: plus today's AI gradings and players past the daily AI cap."""
    readings = list(watch.last)
    try:
        capped, total = await ai_grading_stats(get_usage_caps(request))
    except Exception:  # noqa: BLE001 — the health view must not 500 on a DB blip
        return readings
    limit = float(get_settings().daily_cap_ai_gradings)
    return readings + [
        Reading(
            kind="ai_gradings_today",
            target="all players",
            value=total,
            threshold=limit,
            alarm=False,
        ),
        Reading(
            kind="ai_cap_players_today",
            target="players",
            value=capped,
            threshold=1,
            alarm=capped >= 1,
        ),
    ]
