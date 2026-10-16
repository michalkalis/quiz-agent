"""Admin view of provider credit balances (#193) and ops health (#207)."""

from __future__ import annotations

from fastapi import APIRouter, Depends

from ...config import get_settings
from ...monitoring.ops_watch import Reading, watch
from ...monitoring.provider_balances import ProviderBalance, fetch_provider_balances
from ..admin import verify_admin_key

router = APIRouter()


@router.get("/admin/provider-balances", response_model=list[ProviderBalance])
async def provider_balances(
    _: str = Depends(verify_admin_key),
) -> list[ProviderBalance]:
    """Live account balance per provider; a provider whose API fails is
    `status="error"`, never a 500."""
    return await fetch_provider_balances(get_settings())


@router.get("/admin/ops-health", response_model=list[Reading])
async def ops_health(_: str = Depends(verify_admin_key)) -> list[Reading]:
    """#207: the ops watch's last readings (disk, memory, DB connections,
    response time) with their alarm thresholds; empty until its first run."""
    return watch.last
