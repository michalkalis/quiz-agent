"""App Store Server Notifications V2 payload decoding (#133 close-out gate 2).

Apple POSTs `{"signedPayload": "<JWS>"}`; the JWS decodes to a
`responseBodyV2DecodedPayload` — `notificationType`, `subtype`,
`notificationUUID`, and a `data` object whose `signedTransactionInfo` is
itself a JWS of the familiar transaction payload.

Trust model: the request carries no shared secret, no bearer, no IP allowlist —
the *only* thing that makes a refund notification believable is that its JWS
chains to the configured Apple root and names our bundle. So both JWS layers go
through the very same `AppleJWSVerifier` the order path uses; nothing here
parses an unverified payload.
"""

from __future__ import annotations

from typing import Optional

from pydantic import BaseModel, ConfigDict, Field

from .exceptions import JWSInvalid, JWSWrongBundle
from .verifier import AppleJWSVerifier

# Notification types that reverse a purchase.
#   REFUND — Apple granted the customer a refund (subtypes: none).
#   REVOKE — a family-shared purchase is no longer available to this account.
# Both mean "this transaction bought nothing"; subtypes never change that, so
# they are recorded for provenance but not branched on.
#
# NOT here on purpose: REFUND_DECLINED (nothing was reversed) and
# REFUND_REVERSED (Apple un-refunded — restoring value is a founder decision,
# never an unattended webhook one, see db/models/revoked_transaction.py).
REVOCATION_TYPES = frozenset({"REFUND", "REVOKE"})


class NotificationData(BaseModel):
    model_config = ConfigDict(populate_by_name=True, extra="ignore")

    bundle_id: Optional[str] = Field(default=None, alias="bundleId")
    environment: Optional[str] = None
    signed_transaction_info: Optional[str] = Field(
        default=None, alias="signedTransactionInfo"
    )


class DecodedNotification(BaseModel):
    """Apple's `responseBodyV2DecodedPayload`, verified subset."""

    model_config = ConfigDict(populate_by_name=True, extra="ignore")

    notification_type: str = Field(alias="notificationType")
    notification_uuid: Optional[str] = Field(default=None, alias="notificationUUID")
    subtype: Optional[str] = None
    data: Optional[NotificationData] = None


def decode_notification(
    signed_payload: str, verifier: AppleJWSVerifier
) -> DecodedNotification:
    """Verify the outer notification JWS and return its decoded payload.

    Raises `JWSWrongBundle` when `data.bundleId` is not ours — an
    Apple-signed notification for a *different* app must never reach our
    revocation writer, or anyone with a valid App Store notification for any
    app could revoke transactions here. A notification with no `bundleId` at
    all (some server-level types carry none) is left to the caller: it has no
    transaction, so it cannot revoke anything.
    """
    payload = verifier.verify_payload(signed_payload)
    try:
        notification = DecodedNotification.model_validate(payload)
    except Exception as exc:  # pydantic ValidationError
        raise JWSInvalid(f"not an App Store Server Notification payload: {exc}") from exc

    bundle_id = notification.data.bundle_id if notification.data else None
    if bundle_id is not None and bundle_id != verifier.app_bundle_id:
        raise JWSWrongBundle(
            f"notification bundle mismatch: bundleId={bundle_id!r}, "
            f"expected {verifier.app_bundle_id!r}"
        )
    return notification
