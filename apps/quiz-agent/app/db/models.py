"""ORM tables for auth Phase 1 (issue #60).

Subject identifiers are ``TEXT`` (not ``UUID``) on purpose (decision D4): the
30-day legacy grace path must accept the in-field ``"dev_…"`` device ids, which
are not UUIDs, alongside new UUID-string anon ids.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime

from sqlalchemy import (
    Boolean,
    Date,
    DateTime,
    ForeignKey,
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
    anon_id: Mapped[str] = mapped_column(
        ForeignKey("anonymous_identities.anon_id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
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
