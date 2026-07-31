"""/v1/appstore/notifications — App Store Server Notifications V2 consumer (#133).

Apple POSTs `{"signedPayload": "<JWS>"}` here for every server notification.
We act on the two that reverse a purchase — REFUND and REVOKE — by recording
the transaction in `revoked_transactions` and revoking what it granted.

**Auth = the signature, nothing else.** There is no header, key, or bearer on
this route: Apple does not send one. Authenticity is the JWS chaining to the
configured Apple root plus `data.bundleId` matching ours, both enforced by the
same `AppleJWSVerifier` the order path uses. Configure the URL in App Store
Connect → App Information → App Store Server Notifications (V2):
`https://quiz-pack-api.fly.dev/v1/appstore/notifications`.

**Status codes are retry control.** Apple retries any non-200 for up to ~3 days,
so a non-200 must mean "retrying could work":
- 200 — handled, or knowingly ignored (unknown type, other environment, no
  transaction to act on). Never 500 on a payload that will never parse.
- 401 / 403 — the JWS did not verify, or it is signed for another app. Not
  from Apple (or not for us), so a retry loop is the sender's problem.
- 422 — no `signedPayload` in the body at all (FastAPI validation). Nothing
  Apple sends looks like that, so the retry is the sender's problem too.
"""

from __future__ import annotations

import logging
from typing import Annotated, Optional

import sentry_sdk
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.ext.asyncio import AsyncSession

from ...db.session import get_session
from ...storekit import AppleJWSVerifier, JWSError, JWSWrongBundle
from ...storekit.notifications import REVOCATION_TYPES, decode_notification
from ...storekit.revocation import record_revocation
from ..deps import get_jws_verifier

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/v1/appstore", tags=["appstore"])


class AppStoreNotificationRequest(BaseModel):
    """Apple's request body — exactly one field, camelCase on the wire."""

    model_config = ConfigDict(populate_by_name=True, extra="ignore")

    signed_payload: str = Field(alias="signedPayload")


class NotificationAck(BaseModel):
    status: str
    notification_type: Optional[str] = None
    transaction_id: Optional[str] = None
    revoked_order_ids: list[str] = []


def _ack(status: str, **kwargs: object) -> NotificationAck:
    return NotificationAck(status=status, **kwargs)  # type: ignore[arg-type]


@router.post("/notifications", response_model=NotificationAck)
async def appstore_notifications(
    body: AppStoreNotificationRequest,
    session: Annotated[AsyncSession, Depends(get_session)],
    verifier: Annotated[AppleJWSVerifier, Depends(get_jws_verifier)],
) -> NotificationAck:
    """Consume one App Store Server Notification; revoke on REFUND / REVOKE."""
    try:
        notification = decode_notification(body.signed_payload, verifier)
    except JWSWrongBundle as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except JWSError as exc:
        raise HTTPException(status_code=401, detail=str(exc)) from exc

    kind = notification.notification_type
    if kind not in REVOCATION_TYPES:
        # Everything else Apple sends (renewals, price consent, test pings…).
        # Acknowledged, not an error: a non-200 here would make Apple retry a
        # notification we will never act on, for days.
        logger.info(
            "App Store notification ignored: type=%s subtype=%s uuid=%s",
            kind,
            notification.subtype,
            notification.notification_uuid,
        )
        return _ack("ignored", notification_type=kind)

    signed_tx = notification.data.signed_transaction_info if notification.data else None
    if not signed_tx:
        # A REFUND/REVOKE with no transaction is unusable and unfixable by
        # retrying — acknowledge, but shout, because it means real money moved
        # and we could not act on it.
        message = (
            f"App Store {kind} notification carried no signedTransactionInfo "
            f"(uuid={notification.notification_uuid}) — nothing could be revoked"
        )
        logger.error(message)
        sentry_sdk.capture_message(message, level="error")
        return _ack("unprocessable", notification_type=kind)

    try:
        # NOT `verify()`: a refunded transaction's own payload carries
        # `revocationDate`, so the full gate stack would reject the very
        # transaction we are being told to revoke. Crypto, bundle and
        # environment are still enforced.
        tx = verifier.verify_transaction_info(signed_tx)
    except JWSError as exc:
        # The outer JWS was Apple-signed, so this is not forgery: it is an
        # inner payload we cannot use (most often a different store
        # environment than this deploy serves). Acknowledge so Apple stops
        # retrying, and log which one.
        logger.warning(
            "App Store %s notification: inner transaction not usable by this "
            "deploy (environment=%s): %s",
            kind,
            verifier.environment,
            exc,
        )
        return _ack("ignored", notification_type=kind)

    newly_recorded, revoked_order_ids = await record_revocation(
        session,
        tx,
        notification_type=kind,
        notification_subtype=notification.subtype,
        notification_uuid=notification.notification_uuid,
    )
    logger.warning(
        "App Store %s%s: transaction %s revoked (new=%s, orders=%s)",
        kind,
        f"/{notification.subtype}" if notification.subtype else "",
        tx.transaction_id,
        newly_recorded,
        revoked_order_ids,
    )
    return _ack(
        "revoked" if newly_recorded else "already_revoked",
        notification_type=kind,
        transaction_id=tx.transaction_id,
        revoked_order_ids=revoked_order_ids,
    )
