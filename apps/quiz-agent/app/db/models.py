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
