"""ORM tables for auth Phase 1 (issue #60).

Subject identifiers are ``TEXT`` (not ``UUID``) on purpose (decision D4): the
30-day legacy grace path must accept the in-field ``"dev_…"`` device ids, which
are not UUIDs, alongside new UUID-string anon ids.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime

from sqlalchemy import (
    BigInteger,
    Boolean,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    LargeBinary,
    Text,
)
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from .base import Base, utcnow


class AnonymousIdentity(Base):
    """A server-trusted anonymous subject. Holds new UUID-string ids *and*
    legacy ``dev_…`` device ids (``is_legacy=True``, created during grace)."""

    __tablename__ = "anonymous_identities"

    anon_id: Mapped[str] = mapped_column(Text, primary_key=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, nullable=False
    )
    last_seen_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, nullable=False
    )
    is_legacy: Mapped[bool] = mapped_column(
        Boolean, default=False, nullable=False, server_default="false"
    )
    # Set when an anonymous identity is upgraded to a real account (#61/#62).
    upgraded_to_user_id: Mapped[str | None] = mapped_column(Text, nullable=True)


class RefreshToken(Base):
    """One refresh token, stored as a SHA-256 hash (decision D5).

    Rotation + family-based reuse detection: every ``/refresh`` mints a new
    token in the same ``family_id`` and marks the old one ``used_at``; replay of
    an already-used token revokes the whole family (theft signal)."""

    __tablename__ = "refresh_tokens"

    token_hash: Mapped[str] = mapped_column(Text, primary_key=True)
    family_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True), nullable=False, index=True
    )
    # The subject the token authenticates — the JWT ``sub``. Generalised in #61:
    # an anonymous identity id OR a ``users.id`` after Sign in with Apple, so there
    # is no longer an FK to ``anonymous_identities`` (a user id could not satisfy
    # it — migration 0004 drops it). Name kept as ``anon_id`` to avoid churning the
    # refresh subsystem; read it as "subject id". Deletion removes a user's tokens
    # explicitly (#61 Session C) rather than via the old cascade.
    anon_id: Mapped[str] = mapped_column(Text, nullable=False, index=True)
    issued_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, nullable=False
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    used_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    revoked_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class AttestChallenge(Base):
    """A single-use, short-TTL random challenge for App Attest (issue #60 Part B).

    The server issues a fresh challenge before each attestation/assertion so the
    device signs over a value it could not have precomputed — this is the replay
    defence (a client-chosen nonce gives none). Consumed exactly once: ``used_at``
    is set the moment a challenge backs a verification, so it can never back two.
    """

    __tablename__ = "attest_challenges"

    # The raw challenge value (URL-safe base64 of 32 random bytes). Not a secret —
    # it is echoed to the client and back — so it is stored in the clear, unlike
    # refresh tokens; its security comes from single-use + TTL, not from hashing.
    challenge: Mapped[str] = mapped_column(Text, primary_key=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, nullable=False
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    used_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class AppAttestKey(Base):
    """A hardware-attested App Attest key (issue #60 Part B).

    Established once per install by a verified *attestation*; every later
    *assertion* is checked against the stored public key and must carry a
    strictly greater ``sign_counter`` (the replay guard pyattest does not do for
    us). ``anon_id`` is nullable because the key can be attested before the
    identity is minted; bootstrap binds it.
    """

    __tablename__ = "app_attest_keys"

    # Hex of SHA-256(public key) — the keyId the device reports and Apple binds.
    key_id: Mapped[str] = mapped_column(Text, primary_key=True)
    anon_id: Mapped[str | None] = mapped_column(
        ForeignKey("anonymous_identities.anon_id", ondelete="CASCADE"),
        nullable=True,
        index=True,
    )
    # DER-encoded EC P-256 public key, used to verify every future assertion.
    public_key: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    # Monotonic counter from authData; each accepted assertion must exceed the
    # stored value, after which we persist the new value (transactional).
    sign_counter: Mapped[int] = mapped_column(
        Integer, default=0, nullable=False, server_default="0"
    )
    # "development" or "production" — a dev-attested key must never be honoured in
    # prod (and vice-versa); the aaguid the attestation carried is recorded here.
    environment: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, nullable=False
    )


class DailyUsage(Base):
    """Persistent per-subject daily question count (replaces the in-memory
    ``UsageTracker`` dict). Composite PK keeps one row per subject per UTC day."""

    __tablename__ = "daily_usage"

    subject_id: Mapped[str] = mapped_column(Text, primary_key=True)
    usage_date: Mapped[date] = mapped_column(Date, primary_key=True)
    questions_count: Mapped[int] = mapped_column(
        Integer, default=0, nullable=False, server_default="0"
    )
    is_premium: Mapped[bool] = mapped_column(
        Boolean, default=False, nullable=False, server_default="false"
    )


class User(Base):
    """A real account, minted the first time an anonymous identity signs in with
    Apple (issue #61). The upgrade folds that anon's ``daily_usage`` (keyed on
    ``subject_id``) into this user and stamps
    ``AnonymousIdentity.upgraded_to_user_id`` with ``id`` (decision F3).

    ``apple_sub`` (Apple's stable per-app subject id) is the durable account
    anchor — not the email, which the user can hide/relay. It is also the future
    purchase/entitlement anchor (#50/#62), so there is no ``plan_tier`` here:
    subscriptions are deferred and premium stays on ``daily_usage.is_premium``
    (decision F8).
    """

    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    # Apple's `sub` claim from the verified identity token — unique per account.
    apple_sub: Mapped[str] = mapped_column(Text, unique=True, nullable=False)
    # Apple only sends these on the FIRST authorization, so they are persisted
    # then and nullable forever after (the user may also hide their real email).
    email: Mapped[str | None] = mapped_column(Text, nullable=True)
    full_name: Mapped[str | None] = mapped_column(Text, nullable=True)  # F5
    # Fernet ciphertext of Apple's refresh token (F1/F2). Decrypted only at
    # DELETE /auth/me to drive the Apple token revoke; nullable because Apple
    # does not always return a refresh token (then we use the no-token revoke).
    apple_refresh_token_encrypted: Mapped[bytes | None] = mapped_column(
        LargeBinary, nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, nullable=False
    )


class Product(Base):
    """Catalog row per RevenueCat product/entitlement id (issue #93 Design §1).

    Seeded, read-only at runtime. ``tier`` is the forward-compat seam for
    multiple paid tiers later — a new tier is a new row, never a code branch.
    """

    __tablename__ = "product"

    product_id: Mapped[str] = mapped_column(Text, primary_key=True)
    kind: Mapped[str] = mapped_column(Text, nullable=False)  # subscription|consumable
    tier: Mapped[str] = mapped_column(Text, nullable=False)  # e.g. "unlimited"
    credit_amount: Mapped[int | None] = mapped_column(Integer, nullable=True)


class Subscription(Base):
    """One active-sub projection per durable account (issue #93 Design §1).

    ``account_id`` is PK/UNIQUE on purpose: it is both the webhook upsert's
    ``ON CONFLICT`` target and the account the anon->sign-in fold re-keys to,
    so max-wins/revoke can never fork into duplicate ambiguous rows.
    ``last_event_ts_ms`` is the per-event ordering watermark (RC
    ``event_timestamp_ms``); NULL until the first webhook/sync applies.
    """

    __tablename__ = "subscription"

    account_id: Mapped[str] = mapped_column(Text, primary_key=True)
    product_id: Mapped[str] = mapped_column(
        ForeignKey("product.product_id"), nullable=False
    )
    status: Mapped[str] = mapped_column(Text, nullable=False)  # active|grace|expired
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    rc_original_txn_id: Mapped[str] = mapped_column(Text, nullable=False)
    last_event_ts_ms: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    # #101: store environment the row came from (PRODUCTION|SANDBOX). NULL only
    # on pre-#101 rows; the entitlement read gate treats NULL as NOT entitled.
    environment: Mapped[str | None] = mapped_column(Text, nullable=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )


class CreditLedger(Base):
    """Append-only server-side credit ledger (issue #93 Design §1/§4).

    Apple offers no restore/Family Sharing for consumables, so the balance
    (``SUM(delta)``) must live server-side keyed to account. Split idempotency
    (flaw fix 1): a GRANT dedupes on the store transaction id (present in both
    the webhook and the REST sync payload); a CLAWBACK dedupes on the RC event
    id (event-driven, always supplied on refund). The two partial unique
    indexes are disjoint by ``kind`` so a grant and its clawback — which share
    the same ``store_txn_id`` — never collide.
    """

    __tablename__ = "credit_ledger"
    __table_args__ = (
        Index(
            "ix_credit_ledger_grant_store_txn_id",
            "store_txn_id",
            unique=True,
            postgresql_where="kind = 'grant'",
        ),
        Index(
            "ix_credit_ledger_clawback_rc_event_id",
            "rc_event_id",
            unique=True,
            postgresql_where="kind = 'clawback'",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    account_id: Mapped[str] = mapped_column(Text, nullable=False, index=True)
    delta: Mapped[int] = mapped_column(Integer, nullable=False)
    kind: Mapped[str] = mapped_column(Text, nullable=False)  # grant|consume|clawback
    reason: Mapped[str] = mapped_column(Text, nullable=False)
    store_txn_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    rc_event_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    # #101: store environment for RC-origin rows (PRODUCTION|SANDBOX); NULL on
    # pre-#101 rows and on non-RC kinds (e.g. consume) — audit column only.
    environment: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, nullable=False
    )
