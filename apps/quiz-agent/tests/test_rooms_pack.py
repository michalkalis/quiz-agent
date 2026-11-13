"""#232.2 — which quizzes may become a game together.

"Quota exempt" and "solo only" used to be one flag, so anything free of the
quota was also barred from rooms. Now: the daily challenge stays solo (one
attempt per player), a pack played from a friend's link stays solo (played
once, never handed on), but the host's own FINISHED pack and a shared corpus
round may be played together. A pack still being made is refused, so a game
never waits for questions; and the pack path stays behind the #232 switch.
"""

from __future__ import annotations

import pytest

from app.rooms.network import NetTickets
from app.rooms.service import RoomError, RoomService
from app.rooms.store import MemoryRoomStore
from app.session.manager import SessionManager

pytestmark = pytest.mark.asyncio

PACK = "22222222-2222-2222-2222-222222222222"


class Events:
    def __init__(self):
        self.names = []

    def emit(self, name, **_):
        self.names.append(name)


def _service(status="complete"):
    async def pack_status(pack_id):
        return status if pack_id == PACK else None

    sessions = SessionManager()
    events = Events()
    service = RoomService(
        sessions,
        MemoryRoomStore(),
        NetTickets("r" * 64),
        events,
        pack_status=pack_status,
    )
    return service, sessions, events


async def _host(sessions, **fields):
    session = await sessions.create_session(user_id="host")
    for key, value in fields.items():
        setattr(session, key, value)
    await sessions.update_session(session)
    return session


async def _create(service, session, allow_pack=True):
    return await service.create(
        session.session_id, "host", "Mia", {}, allow_pack=allow_pack
    )


async def test_finished_own_pack_plays_together():
    service, sessions, events = _service()
    session = await _host(sessions, pack_id=PACK)
    room, played = await _create(service, session)
    assert played.room_code == room.room_id and played.pack_id == PACK
    assert events.names == ["room_created", "room_with_pack"]


async def test_pack_still_being_made_is_refused():
    service, sessions, _ = _service(status="generating")
    with pytest.raises(RoomError) as e:
        await _create(service, await _host(sessions, pack_id=PACK))
    assert e.value.status == 422


async def test_pack_stays_solo_while_the_switch_is_off():
    service, sessions, _ = _service()
    with pytest.raises(RoomError):
        await _create(service, await _host(sessions, pack_id=PACK), allow_pack=False)


async def test_daily_challenge_and_a_pack_from_a_link_stay_solo():
    service, sessions, _ = _service()
    daily = await _host(sessions, daily_challenge_date="2026-11-13")
    shared_pack = await _host(sessions, pack_id=PACK, shared_quiz_id="share")
    for session in (daily, shared_pack):
        with pytest.raises(RoomError) as e:
            await _create(service, session)
        assert e.value.status == 422


async def test_shared_round_is_not_barred_by_its_quota_exemption():
    service, sessions, _ = _service()
    session = await _host(sessions, shared_quiz_id="share", fixed_question_ids=["q1"])
    assert session.is_quota_exempt
    room, _ = await _create(service, session, allow_pack=False)
    assert room.session_id == session.session_id
