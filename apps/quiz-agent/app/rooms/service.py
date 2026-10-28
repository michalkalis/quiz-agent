"""Room lifecycle (#212.1): a host turns their idle quiz session into a room,
guests find it on the same network or through the QR/link token and join.

The room row only answers "which session is this game"; everything the game
needs (participants, scores, phase) stays in the quiz session, so the existing
lease and optimistic-version rules cover it and any machine can serve it.
"""

from __future__ import annotations

import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from quiz_shared.models.participant import Participant
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.session import QuizSession

from ..session.manager import SessionManager
from .network import NetTickets
from .store import Room, RoomStore

MAX_PLAYERS = 8
# A room shows up in "games nearby" only while it is fresh: on a hotel or
# office network many strangers share one address.
NEARBY_WINDOW = timedelta(minutes=30)
ROOM_TTL = timedelta(hours=6)
COLORS = (
    "#ff6b2c",
    "#7a5cff",
    "#a3e635",
    "#2c45f5",
    "#3fe0ae",
    "#e8317f",
    "#ffc53d",
    "#16b386",
)


class RoomError(Exception):
    """``status`` is the HTTP status the route answers with."""

    def __init__(self, status: int, detail: str) -> None:
        super().__init__(detail)
        self.status = status
        self.detail = detail


@dataclass(frozen=True)
class NearbyRoom:
    room_id: str
    host_name: str
    host_color: str | None
    player_count: int


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _host(session: QuizSession) -> Participant | None:
    return next((p for p in session.participants if p.is_host), None)


def member(session: QuizSession, subject_id: str) -> Participant | None:
    return next((p for p in session.participants if p.user_id == subject_id), None)


def _free_color(session: QuizSession) -> str:
    used = {p.color for p in session.participants}
    return next((c for c in COLORS if c not in used), COLORS[0])


class RoomService:
    def __init__(
        self, sessions: SessionManager, store: RoomStore, tickets: NetTickets
    ) -> None:
        self.sessions = sessions
        self.store = store
        self.tickets = tickets

    async def create(
        self, session_id: str, subject_id: str, host_name: str, keys: dict[str, str]
    ) -> tuple[Room, QuizSession]:
        """Make the host's idle session a room. Calling it again for the same
        session returns the same room (a retried request must not fork it)."""
        async with self.sessions.session_lock(session_id):
            session = await self.sessions.get_session(session_id)
            if session is None or session.user_id != subject_id:
                raise RoomError(404, "Session not found or expired")
            if session.room_code:
                room = await self.store.get(session.room_code, _now())
                if room is not None:
                    return room, session
            if session.is_quota_exempt:
                raise RoomError(422, "Packs and the daily challenge are solo only")
            if session.phase != SessionPhase.IDLE:
                raise RoomError(409, "The quiz has already started")
            now = _now()
            room = Room(
                room_id=f"r_{secrets.token_hex(8)}",
                session_id=session_id,
                host_subject_id=subject_id,
                join_token=secrets.token_urlsafe(16),
                net_v4=keys.get("v4"),
                net_v6=keys.get("v6"),
                created_at=now,
                expires_at=now + ROOM_TTL,
            )
            await self.store.insert(room)
            host = _host(session) or member(session, subject_id)
            if host is None:
                host = Participant(
                    participant_id=f"p_{secrets.token_hex(4)}",
                    user_id=subject_id,
                    display_name=host_name,
                )
                session.participants.append(host)
            host.is_host = True
            host.display_name = host_name
            host.color = host.color or COLORS[0]
            session.mode = "multiplayer"
            session.room_code = room.room_id
            await self.sessions.update_session(session)
            return room, session

    async def nearby(self, subject_id: str, keys: dict[str, str]) -> list[NearbyRoom]:
        """Rooms waiting to start on the caller's network (not the caller's own)."""
        now = _now()
        found = []
        for room in await self.store.nearby(
            list(keys.values()), now - NEARBY_WINDOW, now
        ):
            if room.host_subject_id == subject_id:
                continue
            session = await self.sessions.get_session(room.session_id)
            if session is None or session.phase != SessionPhase.IDLE:
                continue
            host = _host(session)
            found.append(
                NearbyRoom(
                    room_id=room.room_id,
                    host_name=host.display_name if host else "",
                    host_color=host.color if host else None,
                    player_count=len(session.participants),
                )
            )
        return found

    async def resolve(
        self, subject_id: str, keys: dict[str, str], *, join_token=None, room_id=None
    ) -> Room:
        """The room a guest may join: by the QR/link token from anywhere, or by
        id from the nearby list only when the guest is on the host's network."""
        now = _now()
        if join_token:
            room = await self.store.by_token(join_token, now)
        elif room_id:
            room = await self.store.get(room_id, now)
            if room is not None and not (
                {room.net_v4, room.net_v6} & set(keys.values())
            ):
                room = None
        else:
            room = None
        if room is None:
            raise RoomError(404, "Game not found")
        return room

    async def join(
        self, room: Room, subject_id: str, display_name: str
    ) -> tuple[Participant, QuizSession]:
        async with self.sessions.session_lock(room.session_id):
            session = await self.sessions.get_session(room.session_id)
            if session is None or session.room_code != room.room_id:
                raise RoomError(404, "Game not found")
            existing = member(session, subject_id)
            if existing is not None:
                return existing, session
            if session.phase == SessionPhase.FINISHED:
                raise RoomError(409, "The game has ended")
            if len(session.participants) >= MAX_PLAYERS:
                raise RoomError(409, "The game is full")
            guest = Participant(
                participant_id=f"p_{secrets.token_hex(4)}",
                user_id=subject_id,
                display_name=display_name,
                color=_free_color(session),
            )
            session.participants.append(guest)
            await self.sessions.update_session(session)
            return guest, session

    async def remove(self, room_id: str, subject_id: str, participant_id: str) -> None:
        """The host removes a guest, or a guest leaves. The host cannot be removed."""
        room = await self.store.get(room_id, _now())
        if room is None:
            raise RoomError(404, "Game not found")
        async with self.sessions.session_lock(room.session_id):
            session = await self.sessions.get_session(room.session_id)
            caller = member(session, subject_id) if session else None
            target = session.get_participant(participant_id) if session else None
            if caller is None or target is None:
                raise RoomError(404, "Game not found")
            if target.is_host or not (caller.is_host or caller is target):
                raise RoomError(403, "Only the host can remove other players")
            session.participants.remove(target)
            await self.sessions.update_session(session)

    async def state(
        self, room_id: str, subject_id: str
    ) -> tuple[QuizSession, Participant]:
        """The session behind a room, for a member. Never takes the session
        lease: a poll must not wait behind grading."""
        room = await self.store.get(room_id, _now())
        session = await self.sessions.get_session(room.session_id) if room else None
        you = member(session, subject_id) if session else None
        if session is None or you is None:
            raise RoomError(404, "Game not found")
        return session, you
