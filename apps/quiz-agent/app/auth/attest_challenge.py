"""Single-use App Attest challenges (issue #60 Part B, task 60.10).

Before a device attests a key or signs an assertion, the server hands it a fresh
random challenge with a short TTL. The device signs over that exact value, so it
cannot precompute or replay a signature — the whole point of a *server*-issued
nonce (a client-chosen one gives zero replay protection).

A challenge is consumed exactly once: ``consume`` flips ``used_at`` under a row
lock in the same transaction that reads it, so two concurrent verifications can
never both spend the same challenge.
"""

from __future__ import annotations

import secrets
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..db.models import AttestChallenge


def _now() -> datetime:
    return datetime.now(timezone.utc)


class ChallengeError(Exception):
    """A challenge could not be consumed — unknown, expired, or already used.
    Callers map this to a rejected attestation/assertion (HTTP 400/401)."""


class ChallengeStore:
    def __init__(
        self,
        sessionmaker: async_sessionmaker[AsyncSession],
        *,
        ttl_seconds: int,
    ) -> None:
        self._sessionmaker = sessionmaker
        self._ttl = timedelta(seconds=ttl_seconds)
        self.ttl_seconds = ttl_seconds  # public: the attest-challenge expires_in

    async def issue(self) -> str:
        """Mint, persist, and return a fresh single-use challenge."""
        raw = secrets.token_urlsafe(32)
        now = _now()
        async with self._sessionmaker() as session:
            session.add(
                AttestChallenge(
                    challenge=raw,
                    created_at=now,
                    expires_at=now + self._ttl,
                )
            )
            await session.commit()
        return raw

    async def consume(self, challenge: str) -> None:
        """Spend a challenge exactly once. Raises ``ChallengeError`` if it is
        unknown, expired, or already spent. Locks the row so concurrent callers
        cannot both succeed."""
        async with self._sessionmaker() as session:
            row = (
                await session.execute(
                    select(AttestChallenge)
                    .where(AttestChallenge.challenge == challenge)
                    .with_for_update()
                )
            ).scalar_one_or_none()

            if row is None:
                raise ChallengeError("unknown challenge")
            if row.used_at is not None:
                raise ChallengeError("challenge already used")
            if row.expires_at <= _now():
                raise ChallengeError("challenge expired")

            row.used_at = _now()
            await session.commit()


def build_challenge_store(
    sessionmaker: async_sessionmaker[AsyncSession], settings
) -> ChallengeStore:
    return ChallengeStore(
        sessionmaker, ttl_seconds=settings.attest_challenge_ttl_seconds
    )
