"""Answer flow of a multiplayer room (#212.2): the host's phone starts the
answer time after reading aloud, everyone answers, the host moves on.

The host starts the game with the ordinary ``POST /sessions/{id}/start`` and
fetches the read-aloud audio from ``/sessions/{id}/question/audio``; every
phone follows the game through ``GET /rooms/{id}/state``.
"""

from __future__ import annotations

from typing import Annotated, Literal, Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, BeforeValidator, Field
from quiz_shared.utils.user_text import clean_user_text

from ...auth.identity import AuthSubject
from ...rate_limit import limiter
from ...rooms.service import RoomError, RoomService
from ..deps import get_rooms, require_auth_or_grace
from .rooms import (
    RoomStateResponse,
    raise_http,
    service_or_404,
    state_reply,
    subject_or_401,
)

router = APIRouter()


class QuestionRef(BaseModel):
    question_id: str = Field(max_length=128)


class AnswerRequest(QuestionRef):
    # Shown to every player on the reveal screen: invisible characters out,
    # and a blank answer is a 422, not an empty row.
    answer: Annotated[str, BeforeValidator(
        lambda v: clean_user_text(v).strip() if isinstance(v, str) else v
    )] = Field(
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
