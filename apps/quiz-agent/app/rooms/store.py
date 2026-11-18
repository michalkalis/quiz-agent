"""Room rows (#212.1): Postgres in production, an in-process stand-in for
unit tests and DB-less dev — same pattern as ``app.session.store``."""

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime
from typing import Protocol

from sqlalchemy import delete, or_, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..db.models import MultiplayerRoom


@dataclass(frozen=True)
class Room:
    room_id: str
    session_id: str
    host_subject_id: str
    join_token: str
    net_v4: str | None
    net_v6: str | None
    created_at: datetime
    expires_at: datetime


class RoomStore(Protocol):
    async def insert(self, room: Room) -> None: ...

    async def get(self, room_id: str, now: datetime) -> Room | None: ...

    async def by_token(self, join_token: str, now: datetime) -> Room | None: ...

    async def nearby(
        self, keys: list[str], created_after: datetime, now: datetime
    ) -> list[Room]: ...

    async def forget_host(
        self, subject_id: str, db: AsyncSession | None = None
    ) -> int: ...


def _matches(room: Room, keys: list[str]) -> bool:
    return bool({room.net_v4, room.net_v6} & set(keys))


class MemoryRoomStore:
    def __init__(self) -> None:
        self._rooms: dict[str, Room] = {}

    async def insert(self, room: Room) -> None:
        self._rooms[room.room_id] = replace(room)

    async def get(self, room_id, now):
        room = self._rooms.get(room_id)
        return room if room and room.expires_at > now else None

    async def by_token(self, join_token, now):
        for room in self._rooms.values():
            if room.join_token == join_token and room.expires_at > now:
                return room
        return None

    async def nearby(self, keys, created_after, now):
        rooms = [
            r
            for r in self._rooms.values()
            if r.expires_at > now and r.created_at > created_after and _matches(r, keys)
        ]
        return sorted(rooms, key=lambda r: r.created_at, reverse=True)[:20]

    async def forget_host(self, subject_id, db=None) -> int:
        gone = [k for k, r in self._rooms.items() if r.host_subject_id == subject_id]
        for k in gone:
            del self._rooms[k]
        return len(gone)


def _room(row: MultiplayerRoom) -> Room:
    return Room(
        room_id=row.room_id,
        session_id=row.session_id,
        host_subject_id=row.host_subject_id,
        join_token=row.join_token,
        net_v4=row.net_v4,
        net_v6=row.net_v6,
        created_at=row.created_at,
        expires_at=row.expires_at,
    )


class PostgresRoomStore:
    def __init__(self, sessionmaker: async_sessionmaker[AsyncSession]) -> None:
        self._sm = sessionmaker

    async def insert(self, room: Room) -> None:
        async with self._sm() as db:
            db.add(MultiplayerRoom(**room.__dict__))
            await db.commit()

    async def _one(self, *where) -> Room | None:
        async with self._sm() as db:
            row = (await db.execute(select(MultiplayerRoom).where(*where))).scalar()
        return _room(row) if row else None

    async def get(self, room_id, now):
        return await self._one(
            MultiplayerRoom.room_id == room_id, MultiplayerRoom.expires_at > now
        )

    async def by_token(self, join_token, now):
        return await self._one(
            MultiplayerRoom.join_token == join_token, MultiplayerRoom.expires_at > now
        )

    async def nearby(self, keys, created_after, now):
        if not keys:
            return []
        async with self._sm() as db:
            rows = (
                await db.execute(
                    select(MultiplayerRoom)
                    .where(
                        or_(
                            MultiplayerRoom.net_v4.in_(keys),
                            MultiplayerRoom.net_v6.in_(keys),
                        ),
                        MultiplayerRoom.created_at > created_after,
                        MultiplayerRoom.expires_at > now,
                    )
                    .order_by(MultiplayerRoom.created_at.desc())
                    .limit(20)
                )
            ).scalars()
            return [_room(r) for r in rows]

    async def forget_host(self, subject_id, db=None) -> int:
        stmt = delete(MultiplayerRoom).where(
            MultiplayerRoom.host_subject_id == subject_id
        )
        if db is not None:
            return (await db.execute(stmt)).rowcount or 0
        async with self._sm() as own:
            n = (await own.execute(stmt)).rowcount or 0
            await own.commit()
            return n
