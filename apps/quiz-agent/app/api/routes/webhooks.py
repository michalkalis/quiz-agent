"""RevenueCat webhook endpoint (issue #93, Session C).

``POST /webhooks/revenuecat`` — mounted at the app root (no ``/api/v1`` prefix)
because that is the URL registered in the RevenueCat dashboard (Session 0).

Authenticity is a shared-secret ``Authorization`` header RC sends on every
delivery. It is compared **constant-time and BEFORE the body is parsed**:

* secret unconfigured -> **503** (fail closed — never accept an unauthenticated
  webhook just because the secret is missing);
* header mismatch -> **401** (even for a malformed body, since we reject before
  parsing);
* match -> dispatch the event to ``rc_service.handle_webhook_event``.

All subscription/pack writes live in ``app.usage.rc_service`` (which delegates
the sub-state math to ``app.usage.subscription_state``); this route only does
authenticity + dispatch.
"""

from __future__ import annotations

import hmac
import logging
import os

from fastapi import APIRouter, Depends, HTTPException, Request

from ...usage import rc_service
from ..deps import get_auth_sessionmaker

logger = logging.getLogger(__name__)

router = APIRouter()


@router.post("/webhooks/revenuecat")
async def revenuecat_webhook(
    request: Request,
    sessionmaker=Depends(get_auth_sessionmaker),
):
    secret = os.getenv("REVENUECAT_WEBHOOK_SECRET")
    if not secret:
        # Fail closed: with no configured secret we cannot authenticate the
        # sender, so we must reject rather than accept a spoofable webhook.
        raise HTTPException(status_code=503, detail="RevenueCat webhook not configured")

    provided = request.headers.get("Authorization") or ""
    if not hmac.compare_digest(provided, secret):
        # Rejected BEFORE any body parse — a bad secret 401s regardless of body.
        raise HTTPException(status_code=401, detail="Invalid webhook signature")

    if sessionmaker is None:
        raise HTTPException(status_code=503, detail="Usage persistence unavailable")

    body = await request.json()
    event = body.get("event") or {}
    if not event.get("type") or not event.get("app_user_id"):
        raise HTTPException(status_code=400, detail="Malformed RevenueCat event")

    await rc_service.handle_webhook_event(sessionmaker, event)
    return {"status": "ok"}
