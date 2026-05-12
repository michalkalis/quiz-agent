"""StoreKit signed-transaction payload (issue #33 Task 1.8).

Mirrors Apple's `JWSTransactionDecodedPayload` (camelCase on the wire). Phase 1
needs only the non-consumable subset; subscription-only fields are parsed for
forward compatibility but **not enforced** by the verifier — see plan C2.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator


class SignedTransaction(BaseModel):
    """Decoded `signedTransactionInfo` from a StoreKit V2 JWS.

    Apple emits `purchaseDate` / `expiresDate` as **ms since epoch (int)**, not
    ISO strings — the field validator below coerces them to tz-aware datetimes.
    """

    model_config = ConfigDict(populate_by_name=True, extra="ignore")

    transaction_id: str = Field(alias="transactionId")
    original_transaction_id: str = Field(alias="originalTransactionId")
    product_id: str = Field(alias="productId")
    bundle_id: str = Field(alias="bundleId")
    purchase_date: datetime = Field(alias="purchaseDate")
    environment: str

    expires_date: Optional[datetime] = Field(default=None, alias="expiresDate")
    in_app_ownership_type: Optional[str] = Field(default=None, alias="inAppOwnershipType")
    revocation_reason: Optional[int] = Field(default=None, alias="revocationReason")

    @field_validator("purchase_date", "expires_date", mode="before")
    @classmethod
    def _coerce_ms_epoch(cls, value: Any) -> Any:
        if value is None or isinstance(value, datetime):
            return value
        if isinstance(value, (int, float)):
            return datetime.fromtimestamp(value / 1000, tz=timezone.utc)
        return value
