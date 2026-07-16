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

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..db.models import AttestChallenge

# Cleanup-on-write bounds (#91 item 6): each issue() sweeps a capped batch of
# long-expired rows in its own transaction, so the table cannot grow without
# bound and no scheduler is needed. The grace period keeps recently-expired
# rows around so consume() still answers "expired" (not "unknown") for them.
_PRUNE_BATCH = 500
_PRUNE_GRACE = timedelta(days=1)


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
            doomed = (
                select(AttestChallenge.challenge)
                .where(AttestChallenge.expires_at < now - _PRUNE_GRACE)
                .limit(_PRUNE_BATCH)
            )
            await session.execute(
                delete(AttestChallenge).where(AttestChallenge.challenge.in_(doomed))
            )
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
