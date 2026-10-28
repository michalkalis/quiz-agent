"""Session storage behind ``SessionManager`` (#207 task 207.20).

``PostgresSessionStore`` is production: the ``quiz_sessions`` row is the only
copy of a session, so any machine can serve any request. ``MemorySessionStore``
keeps the same contract inside one process for unit tests and DB-less dev.

Contract shared by both:
- ``get`` returns only active rows, with their ``version``;
- ``update`` is conditional on the version the caller read and returns the new
  version, or None when the row moved on (or is gone) — the caller decides
  which via ``get``;
- ``forget_user`` scrubs an erased account out of stored sessions and ratings
  and bumps the version, so an in-flight writer holding an old copy fails
  instead of writing the id back.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Protocol

from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..db.models import QuestionRatingRow, QuizSessionRow


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def scrub_user(value, user_id: str):
    """``value`` with every string equal to ``user_id`` replaced: a
    ``display_name`` (required on a participant) becomes the anonymous default
    "Player", anything else becomes None."""
    if isinstance(value, dict):
        return {
            k: (
                ("Player" if k == "display_name" else None)
                if v == user_id
                else scrub_user(v, user_id)
            )
            for k, v in value.items()
        }
    if isinstance(value, list):
        return [None if v == user_id else scrub_user(v, user_id) for v in value]
    return value


def forget_in_session(data: dict, user_id: str) -> tuple[dict, bool]:
    """Scrub ``user_id`` out of one stored session; True = keep it active.

    A guest in someone else's multiplayer room (#212) only leaves that room:
    deactivating the session would end the host's game. Every other session
    the user appears in is deactivated, as before."""
    if data.get("mode") == "multiplayer" and data.get("user_id") != user_id:
        gone = {
            p.get("participant_id")
            for p in data.get("participants", [])
            if p.get("user_id") == user_id
        }
        data["participants"] = [
            p for p in data.get("participants", []) if p.get("user_id") != user_id
        ]
        # Their answers go with them (#212.2).
        for rnd in (data.get("room_game") or {}).get("rounds", []):
            rnd["answers"] = {
                k: v for k, v in rnd.get("answers", {}).items() if k not in gone
            }
            rnd["away"] = [k for k in rnd.get("away", []) if k not in gone]
        return scrub_user(data, user_id), True
    return scrub_user(data, user_id), False


@dataclass
class StoredSession:
    data_json: str
    version: int


class SessionStore(Protocol):
    async def insert(
        self, session_id: str, data_json: str, expires_at: datetime
    ) -> None: ...

    async def get(self, session_id: str) -> StoredSession | None: ...

    async def update(
        self,
        session_id: str,
        data_json: str,
        expires_at: datetime,
        expected_version: int,
    ) -> int | None: ...

    async def deactivate(self, session_id: str) -> bool: ...

    async def expire_stale(self) -> int: ...

    async def forget_user(
        self, user_id: str, db: AsyncSession | None = None
    ) -> tuple[int, int]: ...


class MemorySessionStore:
    """One-process stand-in with the Postgres store's semantics."""

    def __init__(self) -> None:
        # session_id -> [data_json, version, is_active, expires_at]
        self._rows: dict[str, list] = {}

    async def insert(self, session_id, data_json, expires_at) -> None:
        self._rows[session_id] = [data_json, 1, True, expires_at]

    async def get(self, session_id) -> StoredSession | None:
        row = self._rows.get(session_id)
        if row is None or not row[2]:
            return None
        return StoredSession(row[0], row[1])

    async def update(self, session_id, data_json, expires_at, expected_version):
        row = self._rows.get(session_id)
        if row is None or not row[2] or row[1] != expected_version:
            return None
        row[0], row[1], row[3] = data_json, row[1] + 1, expires_at
        return row[1]

    async def deactivate(self, session_id) -> bool:
        row = self._rows.get(session_id)
        if row is None or not row[2]:
            return False
        row[2] = False
        return True

    async def expire_stale(self) -> int:
        now = _utcnow()
        n = 0
        for row in self._rows.values():
            if row[2] and row[3] < now:
                row[2] = False
                n += 1
        return n

    async def forget_user(self, user_id, db=None) -> tuple[int, int]:
        n = 0
        for row in self._rows.values():
            if user_id in row[0]:
                data, keep = forget_in_session(json.loads(row[0]), user_id)
                row[0] = json.dumps(data)
                row[1] += 1
                row[2] = row[2] and keep
                n += 1
        return n, 0


class PostgresSessionStore:
    def __init__(self, sessionmaker: async_sessionmaker[AsyncSession]) -> None:
        self._sm = sessionmaker

    async def insert(self, session_id, data_json, expires_at) -> None:
        async with self._sm() as db:
            now = _utcnow()
            db.add(
                QuizSessionRow(
                    session_id=session_id,
                    data_json=data_json,
                    version=1,
                    is_active=True,
                    expires_at=expires_at,
                    created_at=now,
                    updated_at=now,
                )
            )
            await db.commit()

    async def get(self, session_id) -> StoredSession | None:
        async with self._sm() as db:
            row = (
                await db.execute(
                    select(QuizSessionRow.data_json, QuizSessionRow.version).where(
                        QuizSessionRow.session_id == session_id,
                        QuizSessionRow.is_active.is_(True),
                    )
                )
            ).first()
        return StoredSession(row.data_json, row.version) if row else None

    async def update(self, session_id, data_json, expires_at, expected_version):
        async with self._sm() as db:
            new_version = (
                await db.execute(
                    update(QuizSessionRow)
                    .where(
                        QuizSessionRow.session_id == session_id,
                        QuizSessionRow.version == expected_version,
                        QuizSessionRow.is_active.is_(True),
                    )
                    .values(
                        data_json=data_json,
                        expires_at=expires_at,
                        version=QuizSessionRow.version + 1,
                        updated_at=func.now(),
                    )
                    .returning(QuizSessionRow.version)
                )
            ).scalar_one_or_none()
            await db.commit()
        return new_version

    async def deactivate(self, session_id) -> bool:
        async with self._sm() as db:
            result = await db.execute(
                update(QuizSessionRow)
                .where(
                    QuizSessionRow.session_id == session_id,
                    QuizSessionRow.is_active.is_(True),
                )
                .values(
                    is_active=False,
                    version=QuizSessionRow.version + 1,
                    updated_at=func.now(),
                )
            )
            await db.commit()
        return bool(result.rowcount)

    async def expire_stale(self) -> int:
        async with self._sm() as db:
            result = await db.execute(
                update(QuizSessionRow)
                .where(
                    QuizSessionRow.is_active.is_(True),
                    QuizSessionRow.expires_at < func.now(),
                )
                .values(
                    is_active=False,
                    version=QuizSessionRow.version + 1,
                    updated_at=func.now(),
                )
            )
            await db.commit()
        return result.rowcount or 0

    async def forget_user(self, user_id, db=None) -> tuple[int, int]:
        """Unlink ``user_id`` in ``db``'s transaction (the erasure route's, so
        the account delete and this unlink commit together); with no ``db``
        in a transaction of its own."""
        if db is not None:
            return await self._forget(db, user_id)
        async with self._sm() as own:
            counts = await self._forget(own, user_id)
            await own.commit()
            return counts

    @staticmethod
    async def _forget(db: AsyncSession, user_id: str) -> tuple[int, int]:
        rows = (
            await db.execute(
                select(QuizSessionRow.session_id, QuizSessionRow.data_json).where(
                    QuizSessionRow.data_json.contains(user_id, autoescape=True)
                )
            )
        ).all()
        for row in rows:
            data, keep = forget_in_session(json.loads(row.data_json), user_id)
            values = {}
            if not keep:
                # Never serve it again: an ownerless live session would skip
                # every quota gate (they key on the session's user_id).
                values["is_active"] = False
            await db.execute(
                update(QuizSessionRow)
                .where(QuizSessionRow.session_id == row.session_id)
                .values(
                    data_json=json.dumps(data),
                    **values,
                    version=QuizSessionRow.version + 1,
                    updated_at=func.now(),
                )
            )
        ratings = await db.execute(
            update(QuestionRatingRow)
            .where(QuestionRatingRow.user_id == user_id)
            .values(user_id=None)
        )
        return len(rows), ratings.rowcount or 0
