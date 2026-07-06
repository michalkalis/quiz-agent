"""Miscellaneous endpoints: ElevenLabs tokens, usage/freemium, health."""

import os
import logging
from datetime import datetime
from fastapi import APIRouter, Depends, HTTPException, Request

from ..deps import ElevenLabsTokenResponse, get_usage_tracker, require_auth_or_grace
from ...usage.tracker import UsageTracker
from ...rate_limit import limiter

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/elevenlabs/token", response_model=ElevenLabsTokenResponse)
@limiter.limit("10/minute")
async def get_elevenlabs_token(
    request: Request,
    _auth=Depends(require_auth_or_grace),
):
    """Generate a single-use ElevenLabs token for realtime STT.

    Auth + rate-limited (#65): this mints a real, billable ElevenLabs realtime
    token, so it was the clearest budget-drain vector — previously open with no
    limit. `require_auth_or_grace` blocks anonymous callers (once grace is off) and the
    10/min cap bounds abuse per client IP.
    """
    import httpx

    api_key = os.environ.get("ELEVENLABS_API_KEY")
    if not api_key:
        raise HTTPException(
            status_code=503,
            detail="ElevenLabs STT not configured (missing ELEVENLABS_API_KEY)",
        )

    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(
                "https://api.elevenlabs.io/v1/single-use-token/realtime_scribe",
                headers={"xi-api-key": api_key},
                timeout=10.0,
            )
            response.raise_for_status()
            data = response.json()

        return ElevenLabsTokenResponse(token=data["token"])

    except httpx.HTTPStatusError as e:
        raise HTTPException(
            status_code=502,
            detail=f"ElevenLabs API error: {e.response.status_code}",
        )
    except Exception as e:
        raise HTTPException(
            status_code=502,
            detail=f"Failed to get ElevenLabs token: {str(e)}",
        )


# Usage / Freemium


@router.get("/usage/{user_id}")
async def get_usage(
    user_id: str,
    usage_tracker: UsageTracker = Depends(get_usage_tracker),
):
    """Get usage stats for a user (questions used today, limit, reset time)."""
    if usage_tracker is None:
        raise HTTPException(status_code=503, detail="Usage tracking unavailable")
    return await usage_tracker.get_usage(user_id)


@router.post("/usage/{user_id}/premium")
@limiter.limit("5/minute")
async def set_premium(
    request: Request,
    user_id: str,
    usage_tracker: UsageTracker = Depends(get_usage_tracker),
    is_premium: bool = True,
):
    """Set premium status for a user. Requires admin key."""
    admin_key = request.headers.get("X-Admin-Key")
    expected_key = os.getenv("ADMIN_API_KEY")
    if not expected_key or admin_key != expected_key:
        raise HTTPException(status_code=401, detail="Invalid admin key")

    if usage_tracker is None:
        raise HTTPException(status_code=503, detail="Usage tracking unavailable")
    await usage_tracker.set_premium(user_id, is_premium)
    return {"user_id": user_id, "is_premium": is_premium}


# Health


@router.get("/health")
async def health_check():
    """Health check endpoint."""
    return {
        "status": "healthy",
        "service": "quiz-agent",
        "timestamp": datetime.now().isoformat(),
    }
