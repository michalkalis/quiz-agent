"""Post-purchase entitlement sync (issue #93, Session C).

``POST /api/v1/entitlements/sync`` — the purchase->webhook propagation bridge.
RC webhooks land seconds-to-minutes after a purchase, so a user who just
subscribed/bought a pack would otherwise hit the quota gate with no local row.
iOS calls this immediately after a successful purchase; the backend does a
one-shot RC REST ``GET /subscribers/{app_user_id}`` and reconciles local state
to RC's authoritative snapshot (full-state overwrite, monotonic on
``request_date_ms``; pack grants keyed on the store txn id). Off the quiz hot
path — the only request-path call to RC.

Authenticated like the other bearer routes: a *verified* subject is required
(the durable account id is the RC ``app_user_id``); a grace-window / anonymous
request without a verified subject is rejected.
"""

from __future__ import annotations

import logging
import os

from fastapi import APIRouter, Depends, HTTPException

from ...auth.identity import AuthSubject
from ...usage import rc_service
from ..deps import get_auth_sessionmaker, require_auth_or_grace

logger = logging.getLogger(__name__)

router = APIRouter()


@router.post("/entitlements/sync")
async def sync_entitlements(
    subject: AuthSubject = Depends(require_auth_or_grace),
    sessionmaker=Depends(get_auth_sessionmaker),
):
    if not subject.authenticated or not subject.subject_id:
        raise HTTPException(status_code=401, detail="Authentication required")

    api_key = os.getenv("REVENUECAT_API_KEY")
    if not api_key:
        raise HTTPException(status_code=503, detail="RevenueCat API not configured")
    if sessionmaker is None:
        raise HTTPException(status_code=503, detail="Usage persistence unavailable")

    account_id = subject.subject_id
    snapshot = await rc_service.fetch_rc_subscriber(account_id, api_key=api_key)
    await rc_service.apply_sync_snapshot(sessionmaker, account_id, snapshot)
    return {"status": "ok"}
