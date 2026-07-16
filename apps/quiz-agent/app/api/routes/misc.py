"""Miscellaneous endpoints: ElevenLabs tokens, usage/freemium, health."""

import hmac
import os
import logging
from datetime import datetime
from fastapi import APIRouter, Depends, HTTPException, Request

from ...auth.identity import AuthSubject
from ..deps import (
    ElevenLabsTokenResponse,
    UsageResponse,
    get_usage_tracker,
    require_auth_or_grace,
)
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
        logger.error(
            "ElevenLabs token mint failed: upstream %s: %s",
            e.response.status_code,
            e.response.text,
        )
        raise HTTPException(
            status_code=502,
            detail=f"ElevenLabs API error: {e.response.status_code}",
        )
    except Exception as e:
        logger.error("Failed to get ElevenLabs token: %s", e, exc_info=True)
        raise HTTPException(
            status_code=502,
            detail="Failed to get ElevenLabs token",
        )


# Usage / Freemium


@router.get("/usage/me", response_model=UsageResponse)
async def get_usage(
    subject: AuthSubject = Depends(require_auth_or_grace),
    usage_tracker: UsageTracker = Depends(get_usage_tracker),
):
    """Usage stats for the bearer subject (questions used, limit, reset time).

    The subject is derived server-side from the bearer token — the same
    identity every write path (session create, RC webhook grants,
    ``/entitlements/sync``) is keyed on. The retired ``/usage/{user_id}``
    variant read whatever id the client put in the path, so the app displayed
    a different account than the one purchases landed on (#96 P1).
    """
    if usage_tracker is None:
        raise HTTPException(status_code=503, detail="Usage tracking unavailable")
    if not subject.subject_id:
        raise HTTPException(status_code=401, detail="Authentication required")
    return await usage_tracker.get_usage(subject.subject_id)


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
    # Compare as bytes: compare_digest raises TypeError on non-ASCII str (a
    # client header is latin-1-decoded, so an attacker could trigger a 500).
    if (
        not expected_key
        or not admin_key
        or not hmac.compare_digest(admin_key.encode(), expected_key.encode())
    ):
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
