"""App Store Connect webhook → triage (#218 — crash and feedback automation, 218.3).

``POST /api/v1/hooks/asc`` receives TestFlight feedback and crash reports.
Apple signs the raw body: ``x-apple-signature: hmacsha256=<hex>`` is the
HMAC-SHA256 of the body with the secret registered on the webhook
(``ASC_WEBHOOK_SECRET``). Secret unset → 503 (fail closed, like the
RevenueCat webhook); bad or missing signature → 401 before the body is read
as JSON. A valid delivery is answered 200 at once and forwarded as
``asc_feedback`` / ``asc_crash`` with the submission id in the background;
the triage fetches the report itself through the App Store Connect API.
Every other event type (the webhook ping included) is acknowledged and dropped.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request

from ...triage.dispatch import dispatch
from ..deps import get_auth_sessionmaker

logger = logging.getLogger(__name__)
router = APIRouter()

SECRET_ENV = "ASC_WEBHOOK_SECRET"
EVENT_TYPES = {
    "betaFeedbackScreenshotSubmissionCreated": "asc_feedback",
    "betaFeedbackCrashSubmissionCreated": "asc_crash",
    # The eventTypes enum spelling, in case a delivery uses it.
    "BETA_FEEDBACK_SCREENSHOT_SUBMISSION_CREATED": "asc_feedback",
    "BETA_FEEDBACK_CRASH_SUBMISSION_CREATED": "asc_crash",
}


def signature_ok(body: bytes, header: str, secret: str) -> bool:
    expected = (
        "hmacsha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    )
    # Bytes, not str: compare_digest raises on non-ASCII str (a forced 500).
    return hmac.compare_digest(header.strip().lower().encode(), expected.encode())


@router.post("/hooks/asc")
async def asc_webhook(
    request: Request,
    background: BackgroundTasks,
    sessionmaker=Depends(get_auth_sessionmaker),
):
    secret = os.getenv(SECRET_ENV)
    if not secret:
        raise HTTPException(status_code=503, detail="ASC webhook not configured")
    body = await request.body()
    if not signature_ok(body, request.headers.get("x-apple-signature", ""), secret):
        raise HTTPException(status_code=401, detail="Invalid webhook signature")

    try:
        data = json.loads(body).get("data") or {}
    except (ValueError, AttributeError):
        raise HTTPException(status_code=400, detail="Malformed webhook payload")
    event_type = EVENT_TYPES.get(data.get("type") or "")
    if event_type is None:
        logger.info("ASC webhook %r acknowledged, not forwarded", data.get("type"))
        return {"status": "ok"}

    instance = (data.get("relationships") or {}).get("instance") or {}
    target = instance.get("data") or instance  # Apple's examples use both shapes
    payload = {
        "submission_id": target.get("id"),
        "submission_type": target.get("type"),
        "event_id": data.get("id"),
        "timestamp": (data.get("attributes") or {}).get("timestamp"),
    }
    background.add_task(dispatch, event_type, payload, sessionmaker)
    return {"status": "ok"}
