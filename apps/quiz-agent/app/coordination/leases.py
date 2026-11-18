"""Expiring leases in Postgres: the one cross-machine coordination primitive
(#207 task 207.20, resilience design §2.2).

A lease is a row ``(name, holder, expires_at)``. Taking it is a single
``INSERT … ON CONFLICT DO UPDATE … WHERE expires_at < now() OR holder = :me``
statement, so two machines can never both hold it, and a holder that crashed
frees it simply by expiring. Nothing is held on a database connection between
statements: prod reaches Postgres through HAProxy, which cuts idle connections
after 30 min, and the pool is small, so a session-level advisory lock held
across a paid STT/LLM call would be both fragile and expensive.
"""

from __future__ import annotations

import uuid

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

_ACQUIRE = text(
    """
    INSERT INTO coordination_leases (name, holder, expires_at)
    VALUES (:name, :holder, now() + make_interval(secs => :ttl))
    ON CONFLICT (name) DO UPDATE
        SET holder = EXCLUDED.holder, expires_at = EXCLUDED.expires_at
        WHERE coordination_leases.expires_at < now()
           OR coordination_leases.holder = EXCLUDED.holder
    RETURNING holder
    """
)
_RELEASE = text(
    "DELETE FROM coordination_leases WHERE name = :name AND holder = :holder"
)
_PURGE = text(
    "DELETE FROM coordination_leases "
    "WHERE expires_at < now() - make_interval(secs => :grace)"
)


def new_holder() -> str:
    """A holder token unique to one acquisition (or one process, for a
    renewable lease such as the monitor leader)."""
    return uuid.uuid4().hex


class LeaseStore:
    def __init__(self, sessionmaker: async_sessionmaker[AsyncSession]) -> None:
        self._sm = sessionmaker

    async def try_acquire(self, name: str, holder: str, ttl_s: float) -> bool:
        """Take or renew ``name`` for ``ttl_s`` seconds. True when ``holder``
        now owns it; False when someone else holds an unexpired lease."""
        async with self._sm() as db:
            row = (
                await db.execute(
                    _ACQUIRE, {"name": name, "holder": holder, "ttl": float(ttl_s)}
                )
            ).first()
            await db.commit()
        return row is not None

    async def release(self, name: str, holder: str) -> None:
        """Give the lease back early (only if still ours)."""
        async with self._sm() as db:
            await db.execute(_RELEASE, {"name": name, "holder": holder})
            await db.commit()

    async def purge_expired(self, grace_s: float = 3600.0) -> int:
        """Drop rows of holders that died without releasing (housekeeping)."""
        async with self._sm() as db:
            result = await db.execute(_PURGE, {"grace": float(grace_s)})
            await db.commit()
        return result.rowcount or 0
