"""Same-room multiplayer endpoints (#212.1).

New endpoints only, behind ``multiplayer_enabled`` (404 when off), so live
builds never see a change. A room wraps the host's ordinary quiz session; the
host keeps driving it through the existing ``/sessions/{id}`` routes.
"""

from __future__ import annotations

from typing import Annotated, List, Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from pydantic import BaseModel, BeforeValidator, Field

from ...auth.identity import AuthSubject
from ...config import get_settings
from ...rate_limit import fly_client_ip, limiter
from ...rooms.network import collect_keys, network_key
from quiz_shared.models.room import RoomGame
from quiz_shared.utils.user_text import clean_user_text

from ...rooms.service import NearbyRoom, RoomError, RoomService
from ..deps import get_rooms, require_auth_or_grace
from .room_view import GameView, game_view, stable

router = APIRouter()

# Other players see this name (lobby, results, the nearby list), so it is one
# line of visible text: no bidi tricks, no line breaks, not blank.
_PlayerName = Annotated[
    str,
    BeforeValidator(
        lambda v: " ".join(clean_user_text(v).split()) if isinstance(v, str) else v
    ),
    Field(min_length=1, max_length=24),
]
_TICKETS = Field(default_factory=list, max_length=4)


class NetProbeResponse(BaseModel):
    family: Optional[str] = Field(description="v4 | v6; null off the public internet")
    ticket: Optional[str] = None


class CreateRoomRequest(BaseModel):
    session_id: str
    host_name: _PlayerName
    net_tickets: List[str] = _TICKETS
    # #212.2: the host's choices, the same for every player.
    reveal_mode: Literal["question", "round"] = "question"
    thinking_seconds: int = Field(10, ge=3, le=60)
    reads_aloud: bool = True


class RoomResponse(BaseModel):
    room_id: str
    join_token: str
    session_id: str


class NearbyRequest(BaseModel):
    net_tickets: List[str] = _TICKETS


class NearbyRoomOut(BaseModel):
    room_id: str
    host_name: str
    host_color: Optional[str]
    player_count: int


class NearbyResponse(BaseModel):
    rooms: List[NearbyRoomOut]


class JoinRoomRequest(BaseModel):
    display_name: _PlayerName
    join_token: Optional[str] = Field(None, max_length=64)
    room_id: Optional[str] = Field(None, max_length=64)
    net_tickets: List[str] = _TICKETS
    # #212.5: how a token reached the guest; older builds send nothing.
    via: Literal["qr", "link"] = "link"


class RoomPlayer(BaseModel):
    participant_id: str
    display_name: str
    color: Optional[str]
    is_host: bool
    score: float


class RoomStateResponse(GameView):
    room_id: str
    version: int
    changed: bool = Field(description="False: nothing changed since `since`")
    status: Optional[str] = Field(None, description="lobby | playing | finished")
    you: Optional[str] = Field(None, description="Your participant_id")
    is_host: Optional[bool] = None
    question_number: Optional[int] = None
    max_questions: Optional[int] = None
    players: Optional[List[RoomPlayer]] = None


def subject_or_401(subject: AuthSubject) -> str:
    if not (subject.authenticated and subject.subject_id):
        raise HTTPException(status_code=401, detail="Sign-in required")
    return subject.subject_id


def service_or_404(rooms: Optional[RoomService]) -> RoomService:
    if rooms is None or not get_settings().multiplayer_enabled:
        raise HTTPException(status_code=404, detail="Not found")
    return rooms


def _keys(request: Request, tickets: List[str], subject_id: str, rooms: RoomService):
    return collect_keys(fly_client_ip(request), tickets, subject_id, rooms.tickets)


def raise_http(e: RoomError):
    raise HTTPException(status_code=e.status, detail=e.detail)


@router.get("/rooms/net-probe", response_model=NetProbeResponse)
@limiter.limit("30/minute")
async def net_probe(
    request: Request,
    rooms: Optional[RoomService] = Depends(get_rooms),
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """Called by the app on an IPv4-only and an IPv6-only hostname, so the
    server learns both of the phone's network keys (see rooms.network)."""
    subject_id = subject_or_401(subject)
    service = service_or_404(rooms)
    key = network_key(fly_client_ip(request))
    if key is None:
        return NetProbeResponse(family=None)
    return NetProbeResponse(
        family=key[:2], ticket=service.tickets.issue(subject_id, key)
    )


@router.post("/rooms", response_model=RoomResponse)
@limiter.limit("10/minute")
async def create_room(
    request: Request,
    body: CreateRoomRequest,
    rooms: Optional[RoomService] = Depends(get_rooms),
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    subject_id = subject_or_401(subject)
    service = service_or_404(rooms)
    keys = _keys(request, body.net_tickets, subject_id, service)
    try:
        room, _ = await service.create(
            body.session_id,
            subject_id,
            body.host_name,
            keys,
            RoomGame(
                reveal_mode=body.reveal_mode,
                thinking_seconds=body.thinking_seconds,
                reads_aloud=body.reads_aloud,
            ),
        )
    except RoomError as e:
        raise_http(e)
    return RoomResponse(
        room_id=room.room_id, join_token=room.join_token, session_id=room.session_id
    )


@router.post("/rooms/nearby", response_model=NearbyResponse)
@limiter.limit("30/minute")
async def nearby_rooms(
    request: Request,
    body: NearbyRequest,
    rooms: Optional[RoomService] = Depends(get_rooms),
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """Games waiting to start on the caller's Wi-Fi. Shows the host's name and
    the player count only."""
    subject_id = subject_or_401(subject)
    service = service_or_404(rooms)
    found: list[NearbyRoom] = await service.nearby(
        subject_id, _keys(request, body.net_tickets, subject_id, service)
    )
    return NearbyResponse(rooms=[NearbyRoomOut(**r.__dict__) for r in found])


@router.post(
    "/rooms/join", response_model=RoomStateResponse, response_model_exclude_none=True
)
@limiter.limit("20/minute")
async def join_room(
    request: Request,
    body: JoinRoomRequest,
    rooms: Optional[RoomService] = Depends(get_rooms),
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    subject_id = subject_or_401(subject)
    service = service_or_404(rooms)
    try:
        room = await service.resolve(
            subject_id,
            _keys(request, body.net_tickets, subject_id, service),
            join_token=body.join_token,
            room_id=body.room_id,
        )
        via = body.via if body.join_token else "nearby"
        await service.join(room, subject_id, body.display_name, via)
    except RoomError as e:
        raise_http(e)
    return await state_reply(service, room.room_id, subject_id, since=None)


@router.delete("/rooms/{room_id}/players/{participant_id}", status_code=204)
async def remove_player(
    room_id: str,
    participant_id: str,
    rooms: Optional[RoomService] = Depends(get_rooms),
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """The host removes a guest, or a guest leaves the game."""
    subject_id = subject_or_401(subject)
    try:
        await service_or_404(rooms).remove(room_id, subject_id, participant_id)
    except RoomError as e:
        raise_http(e)
    return Response(status_code=204)


# Nulls are left out: an unchanged poll is three fields, ~8 phones a second.
@router.get(
    "/rooms/{room_id}/state",
    response_model=RoomStateResponse,
    response_model_exclude_none=True,
)
async def room_state(
    room_id: str,
    since: Optional[int] = Query(None, description="Last version you saw"),
    rooms: Optional[RoomService] = Depends(get_rooms),
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """Polled about once a second by every phone in the room. ``since`` = the
    last ``version`` seen: unchanged → a tiny ``changed: false`` reply."""
    subject_id = subject_or_401(subject)
    return await state_reply(service_or_404(rooms), room_id, subject_id, since=since)


async def state_reply(
    service: RoomService, room_id: str, subject_id: str, *, since: Optional[int]
) -> RoomStateResponse:
    """The room as ``subject_id`` sees it. A question past its time is closed
    in the background (#212.2), so this never waits on grading."""
    try:
        session, you = await service.state(room_id, subject_id)
    except RoomError as e:
        raise_http(e)
    if service.play is not None:
        service.play.close_if_due(session)
    return _state(room_id, session, you, since=since)


def _status(session) -> str:
    phase = getattr(session.phase, "value", session.phase)
    return {"idle": "lobby", "finished": "finished"}.get(phase, "playing")


def _state(room_id, session, you, *, since) -> RoomStateResponse:
    version = session._store_version
    if since is not None and since == version and stable(session):
        return RoomStateResponse(room_id=room_id, version=version, changed=False)
    return RoomStateResponse(
        **game_view(session, you).model_dump(),
        room_id=room_id,
        version=version,
        changed=True,
        status=_status(session),
        you=you.participant_id,
        is_host=you.is_host,
        question_number=session.question_number,
        max_questions=session.max_questions,
        players=[
            RoomPlayer(
                participant_id=p.participant_id,
                display_name=p.display_name,
                color=p.color,
                is_host=p.is_host,
                score=p.score,
            )
            for p in session.participants
        ],
    )
