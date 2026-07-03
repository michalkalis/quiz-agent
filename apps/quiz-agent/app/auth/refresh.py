"""Rotating refresh tokens with family-based reuse detection (decision D5).

RFC 9700 requires rotation + reuse detection for native/public clients. Each
``/refresh`` mints a *new* refresh token in the same ``family_id`` and marks the
presented one used; replaying an already-used token is a theft signal → the
whole family is revoked and the client must re-bootstrap.

Tokens are never stored in the clear: only the SHA-256 hash of a 32-byte opaque
random value lives in the DB, so a database read cannot mint valid tokens.
"""

from __future__ import annotations

import hashlib
import secrets
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..db.models import RefreshToken


def _hash(raw: str) -> str:
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _now() -> datetime:
    return datetime.now(timezone.utc)


class RefreshError(Exception):
    """Refresh failed for a non-theft reason (unknown/expired/revoked token, or
    the family hit its absolute age cap). Caller maps to 401 → re-bootstrap."""


class RefreshReuseDetected(RefreshError):
    """An already-used refresh token was replayed — token theft signal. The
    whole family has been revoked; caller maps to 401 → re-bootstrap."""


@dataclass(frozen=True)
class IssuedRefresh:
    raw_token: str  # returned to the client once; never persisted in the clear
    expires_at: datetime
    family_id: uuid.UUID


@dataclass(frozen=True)
class RotationResult:
    refresh: IssuedRefresh
    anon_id: str


class RefreshTokenStore:
    def __init__(
        self,
        sessionmaker: async_sessionmaker[AsyncSession],
        *,
        ttl_days: int,
        family_max_days: int,
    ) -> None:
        self._sessionmaker = sessionmaker
        self._ttl = timedelta(days=ttl_days)
        self._family_max = timedelta(days=family_max_days)

    def _new_token_row(
        self,
        anon_id: str,
        family_id: uuid.UUID,
        now: datetime,
        family_deadline: datetime,
    ) -> tuple[RefreshToken, IssuedRefresh]:
        raw = secrets.token_urlsafe(32)
        # Sliding window, never past the family's absolute cap.
        expires_at = min(now + self._ttl, family_deadline)
        row = RefreshToken(
            token_hash=_hash(raw),
            family_id=family_id,
            anon_id=anon_id,
            issued_at=now,
            expires_at=expires_at,
        )
        return row, IssuedRefresh(
            raw_token=raw, expires_at=expires_at, family_id=family_id
        )

    async def issue(self, session: AsyncSession, anon_id: str) -> IssuedRefresh:
        """Mint the first refresh token of a new family for ``anon_id``.

        Runs inside the caller's transaction (bootstrap creates the identity
        row and the token atomically); the caller commits.
        """
        now = _now()
        family_id = uuid.uuid4()
        row, issued = self._new_token_row(
            anon_id, family_id, now, now + self._family_max
        )
        session.add(row)
        await session.flush()
        return issued

    async def revoke_family(self, raw_token: str) -> None:
        """Revoke the presented token's whole family (sign-out).

        Idempotent and silent on unknown/already-revoked tokens: logout must
        never leak whether a guessed token was valid, and a double sign-out is
        not an error. Unlike ``rotate`` this never mints a replacement — after
        sign-out the client bootstraps a fresh identity instead."""
        token_hash = _hash(raw_token)
        async with self._sessionmaker() as session:
            row = (
                await session.execute(
                    select(RefreshToken).where(RefreshToken.token_hash == token_hash)
                )
            ).scalar_one_or_none()
            if row is None:
                return
            await session.execute(
                update(RefreshToken)
                .where(
                    RefreshToken.family_id == row.family_id,
                    RefreshToken.revoked_at.is_(None),
                )
                .values(revoked_at=_now())
            )
            await session.commit()

    async def rotate(self, raw_token: str) -> RotationResult:
        """Verify + rotate a presented refresh token in one atomic transaction.

        Raises ``RefreshReuseDetected`` (family revoked) on replay of a used
        token, or ``RefreshError`` for unknown/expired/revoked/too-old tokens.
        """
        token_hash = _hash(raw_token)
        async with self._sessionmaker() as session:
            row = (
                await session.execute(
                    select(RefreshToken)
                    .where(RefreshToken.token_hash == token_hash)
                    .with_for_update()
                )
            ).scalar_one_or_none()

            if row is None:
                raise RefreshError("unknown refresh token")

            now = _now()

            if row.revoked_at is not None:
                raise RefreshError("refresh token revoked")

            if row.used_at is not None:
                # Replay of an already-rotated token → revoke the whole family
                # and persist that revocation before signalling the caller.
                await session.execute(
                    update(RefreshToken)
                    .where(
                        RefreshToken.family_id == row.family_id,
                        RefreshToken.revoked_at.is_(None),
                    )
                    .values(revoked_at=now)
                )
                await session.commit()
                raise RefreshReuseDetected("refresh token reuse — family revoked")

            if row.expires_at <= now:
                raise RefreshError("refresh token expired")

            family_start = (
                await session.execute(
                    select(func.min(RefreshToken.issued_at)).where(
                        RefreshToken.family_id == row.family_id
                    )
                )
            ).scalar_one()
            family_deadline = family_start + self._family_max
            if now >= family_deadline:
                raise RefreshError("refresh token family reached absolute age cap")

            row.used_at = now
            new_row, issued = self._new_token_row(
                row.anon_id, row.family_id, now, family_deadline
            )
            session.add(new_row)
            await session.commit()
            return RotationResult(refresh=issued, anon_id=row.anon_id)


def build_refresh_store(
    sessionmaker: async_sessionmaker[AsyncSession], settings
) -> RefreshTokenStore:
    return RefreshTokenStore(
        sessionmaker,
        ttl_days=settings.refresh_token_ttl_days,
        family_max_days=settings.refresh_family_max_days,
    )
