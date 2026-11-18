"""Room lifecycle (#212.1): a host turns their idle quiz session into a room,
guests find it on the same network or through the QR/link token and join.

The room row only answers "which session is this game"; everything the game
needs (participants, scores, phase) stays in the quiz session, so the existing
lease and optimistic-version rules cover it and any machine can serve it.
"""

from __future__ import annotations

import secrets
from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone

from quiz_shared.models.participant import Participant
from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.room import RoomGame
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
        self,
        sessions: SessionManager,
        store: RoomStore,
        tickets: NetTickets,
        analytics=None,
        pack_status=None,
    ) -> None:
        self.sessions = sessions
        self.store = store
        self.tickets = tickets
        # #232.2: async pack_id -> question_packs.generation_status (the
        # question retriever's); a pack plays together only once complete.
        self.pack_status = pack_status
        # #212.5: room_created / room_joined (app.analytics.AnalyticsRecorder).
        self.analytics = analytics
        # #212.2 answer flow (rooms.play.RoomPlay), wired once the quiz flow exists.
        self.play = None

    async def create(
        self,
        session_id: str,
        subject_id: str,
        host_name: str,
        keys: dict[str, str],
        game: RoomGame | None = None,
        allow_pack: bool = False,
        room_id: str | None = None,
    ) -> tuple[Room, QuizSession]:
        """Make the host's idle session a room. Calling it again for the same
        session returns the same room (a retried request must not fork it).

        #232.2: the host's own custom pack plays together once it is finished
        (``allow_pack`` = the shared-quiz switch); one still being made is
        refused, so a game never has to wait for questions.

        #240.9: with ``room_id`` (the host's room) the room moves to this
        session instead of a new room being made (see ``_move``)."""
        async with self.sessions.session_lock(session_id):
            session = await self.sessions.get_session(session_id)
            if session is None or session.user_id != subject_id:
                raise RoomError(404, "Session not found or expired")
            if session.room_code:
                room = await self.store.get(session.room_code, _now())
                if room is not None:
                    return room, session
            if session.is_solo_only:
                raise RoomError(
                    422,
                    "A round with kids is solo only"
                    if session.age_band
                    else "The daily challenge is solo only",
                )
            if session.pack_id and not await self._pack_ready(session, allow_pack):
                raise RoomError(422, "Only a finished pack can be played together")
            if session.phase != SessionPhase.IDLE:
                raise RoomError(409, "The quiz has already started")
            now = _now()
            game = game or RoomGame()
            if room_id:
                room = await self._move(room_id, session, subject_id, game, now)
            else:
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
            session.room_game = game
            # The app's session starts with 30 minutes and nothing in a room
            # extends it; a game lives as long as its room.
            session.expires_at = max(session.expires_at, room.expires_at)
            # One picture on several phones is not in the first version.
            session.include_images = False
            await self.sessions.update_session(session)
            # A moved room was counted when it was made (#240.9).
            if not room_id:
                self._emit("room_created", subject_id, session_id, room.room_id)
            if session.pack_id:
                self._emit("room_with_pack", subject_id, session_id, room.room_id)
            return room, session

    async def _move(
        self,
        room_id: str,
        session: QuizSession,
        subject_id: str,
        game: RoomGame,
        now: datetime,
    ) -> Room:
        """#240.9: the host's room moves to their new idle session with
        everyone in it, so nobody is invited again: "play again" once a game
        is over, or other content picked in the lobby. The room id, the link
        and the QR stay; every phone keeps polling the same room and sees the
        new lobby. Mid-game it is refused (409). The old session drops the
        room, so a join racing the move fails instead of landing in it."""
        room = await self.store.get(room_id, now)
        if room is None or room.host_subject_id != subject_id:
            raise RoomError(404, "Game not found")
        if room.session_id == session.session_id:
            raise RoomError(409, "The game is already in this room")
        async with self.sessions.session_lock(room.session_id):
            old = await self.sessions.get_session(room.session_id)
            if old is None or old.room_game is None:
                raise RoomError(404, "Game not found")
            if old.phase not in (SessionPhase.IDLE, SessionPhase.FINISHED):
                raise RoomError(409, "The game is still running")
            again = old.phase == SessionPhase.FINISHED
            session.participants = [
                Participant(
                    participant_id=p.participant_id,
                    user_id=p.user_id,
                    display_name=p.display_name,
                    color=p.color,
                    is_host=p.is_host,
                )
                for p in old.participants
            ]
            game.version_base = old._store_version + old.room_game.version_base + 1
            game.rematch = again or old.room_game.rematch
            old.room_code = None
            await self.sessions.update_session(old)
        expires_at = max(room.expires_at, now + ROOM_TTL)
        await self.store.move(room.room_id, session.session_id, expires_at)
        if again:
            self._emit(
                "room_rematch",
                subject_id,
                session.session_id,
                room.room_id,
                players=len(session.participants),
            )
        return replace(room, session_id=session.session_id, expires_at=expires_at)

    async def _pack_ready(self, session: QuizSession, allow_pack: bool) -> bool:
        if not allow_pack or self.pack_status is None:
            return False
        return await self.pack_status(session.pack_id) == "complete"

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
        self, room: Room, subject_id: str, display_name: str, via: str = "link"
    ) -> tuple[Participant, QuizSession]:
        """``via``: how the guest found the game (nearby list, QR or link)."""
        async with self.sessions.session_lock(room.session_id):
            session = await self.sessions.get_session(room.session_id)
            if session is None or session.room_code != room.room_id:
                raise RoomError(404, "Game not found")
            existing = member(session, subject_id)
            if existing is not None:
                # Joining again in the lobby is how a guest changes their name.
                if (
                    existing.display_name != display_name
                    and session.phase == SessionPhase.IDLE
                ):
                    existing.display_name = display_name
                    await self.sessions.update_session(session)
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
            self._emit(
                "room_joined", subject_id, room.session_id, room.room_id, via=via
            )
            return guest, session

    def _emit(self, name, subject_id, session_id, room_id, **properties) -> None:
        if self.analytics is not None:
            self.analytics.emit(
                name,
                subject_id=subject_id,
                session_id=session_id,
                properties={"room_id": room_id, **properties},
            )

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
