"""Answer flow of a multiplayer room (#212.2): the host's phone starts the
answer time after reading aloud, everyone answers, the host moves on.

The host starts the game with the ordinary ``POST /sessions/{id}/start`` and
fetches the read-aloud audio from ``/sessions/{id}/question/audio``; every
phone follows the game through ``GET /rooms/{id}/state``.
"""

from __future__ import annotations

from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field

from ...auth.identity import AuthSubject
from ...rate_limit import limiter
from ...rooms.service import RoomError, RoomService
from ..deps import (
    get_question_retriever,
    get_rooms,
    get_session_manager,
    get_translation_service,
    get_tts_service,
    require_auth_or_grace,
)
from .rooms import (
    RoomStateResponse,
    raise_http,
    service_or_404,
    state_reply,
    subject_or_401,
)
from .tts import question_audio_response

router = APIRouter()


class QuestionRef(BaseModel):
    question_id: str = Field(max_length=128)


class AnswerRequest(QuestionRef):
    answer: str = Field(
        min_length=1, max_length=200, description="Option key (a–d) or typed text"
    )


class SettingsRequest(BaseModel):
    """Only the fields sent change."""

    reveal_mode: Optional[Literal["question", "round"]] = None
    thinking_seconds: Optional[int] = Field(None, ge=3, le=60)
    reads_aloud: Optional[bool] = None


@router.post(
    "/rooms/{room_id}/settings",
    response_model=RoomStateResponse,
    response_model_exclude_none=True,
)
@limiter.limit("30/minute")
async def change_settings(
    request: Request,
    room_id: str,
    body: SettingsRequest,
    rooms: Optional[RoomService] = Depends(get_rooms),
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """Host: the game's rules (#213.8), in the lobby or between questions."""
    subject_id, service = subject_or_401(subject), service_or_404(rooms)
    await _run(service.play.settings(room_id, subject_id, **body.model_dump()))
    return await state_reply(service, room_id, subject_id, since=None)


class PauseRequest(BaseModel):
    paused: bool


@router.post(
    "/rooms/{room_id}/pause",
    response_model=RoomStateResponse,
    response_model_exclude_none=True,
)
@limiter.limit("30/minute")
async def pause_reveal(
    request: Request,
    room_id: str,
    body: PauseRequest,
    rooms: Optional[RoomService] = Depends(get_rooms),
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """Host: stay on the revealed question (guests see the pause) or resume."""
    subject_id, service = subject_or_401(subject), service_or_404(rooms)
    await _run(service.play.pause(room_id, subject_id, body.paused))
    return await state_reply(service, room_id, subject_id, since=None)


@router.post(
    "/rooms/{room_id}/open",
    response_model=RoomStateResponse,
    response_model_exclude_none=True,
)
@limiter.limit("60/minute")
async def open_question(
    request: Request,
    room_id: str,
    body: QuestionRef,
    rooms: Optional[RoomService] = Depends(get_rooms),
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """Host: the question was read aloud, start the answer time."""
    subject_id, service = subject_or_401(subject), service_or_404(rooms)
    await _run(service.play.open(room_id, subject_id, body.question_id))
    return await state_reply(service, room_id, subject_id, since=None)


@router.post(
    "/rooms/{room_id}/answer",
    response_model=RoomStateResponse,
    response_model_exclude_none=True,
)
@limiter.limit("60/minute")
async def answer_question(
    request: Request,
    room_id: str,
    body: AnswerRequest,
    rooms: Optional[RoomService] = Depends(get_rooms),
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """Any player: the answer to the current question (final once sent)."""
    subject_id, service = subject_or_401(subject), service_or_404(rooms)
    await _run(service.play.answer(room_id, subject_id, body.question_id, body.answer))
    return await state_reply(service, room_id, subject_id, since=None)


@router.post("/rooms/{room_id}/away", status_code=204)
@limiter.limit("60/minute")
async def left_app(
    request: Request,
    room_id: str,
    body: QuestionRef,
    rooms: Optional[RoomService] = Depends(get_rooms),
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """Any player: the app went to the background during the question (not
    sent during a phone call). Only the host sees it, at the end."""
    subject_id, service = subject_or_401(subject), service_or_404(rooms)
    await _run(service.play.away(room_id, subject_id, body.question_id))


@router.post(
    "/rooms/{room_id}/next",
    response_model=RoomStateResponse,
    response_model_exclude_none=True,
)
@limiter.limit("30/minute")
async def next_question(
    request: Request,
    room_id: str,
    rooms: Optional[RoomService] = Depends(get_rooms),
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """Host: the next question for everyone, or the final ranking."""
    subject_id, service = subject_or_401(subject), service_or_404(rooms)
    await _run(service.play.next(room_id, subject_id))
    return await state_reply(service, room_id, subject_id, since=None)


async def _run(coro) -> None:
    try:
        await coro
    except RoomError as e:
        raise_http(e)


@router.get("/rooms/{room_id}/question/audio")
@limiter.limit("60/minute")
async def room_question_audio(
    request: Request,
    room_id: str,
    question_id: str = Query(max_length=128),
    rooms: Optional[RoomService] = Depends(get_rooms),
    session_manager=Depends(get_session_manager),
    tts_service=Depends(get_tts_service),
    question_retriever=Depends(get_question_retriever),
    translation_service=Depends(get_translation_service),
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """The current question read aloud, for any member (#230.1): a guest in
    another city hears what the host's phone reads. Same cached audio as
    ``/sessions/{id}/question/audio``. Not a member → 404; lobby, finished or
    not the current question → 409 (nothing is read before the guest sees it)."""
    subject_id, service = subject_or_401(subject), service_or_404(rooms)
    try:
        session, _ = await service.state(room_id, subject_id)
    except RoomError as e:
        raise_http(e)
    phase = getattr(session.phase, "value", session.phase)
    if phase in ("idle", "finished") or session.current_question_id != question_id:
        raise HTTPException(status_code=409, detail="Not the current question")
    return await question_audio_response(
        session, session_manager, tts_service, question_retriever, translation_service
    )
