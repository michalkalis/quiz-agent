"""Answer flow of a multiplayer room (#212.2): the host's phone starts the
answer time after reading aloud, everyone answers, the host moves on.

The host starts the game with the ordinary ``POST /sessions/{id}/start`` and
fetches the read-aloud audio from ``/sessions/{id}/question/audio``; every
phone follows the game through ``GET /rooms/{id}/state``.
"""

from __future__ import annotations

from typing import Annotated, Literal, Optional

import logging

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    HTTPException,
    Query,
    Request,
    UploadFile,
)
from pydantic import BaseModel, BeforeValidator, Field
from quiz_shared.sentry_privacy import user_text_log
from quiz_shared.utils.user_text import clean_user_text

from ...auth.identity import AuthSubject
from ...config import get_settings
from ...quiz.errors import InvalidSubmission
from ...rate_limit import limiter
from ...rooms import rounds
from ...rooms.service import RoomError, RoomService
from ...usage.caps import (
    STT_SECONDS,
    DailyCapExceeded,
    UsageCaps,
    answer_attempts,
    recording_seconds,
)
from ...voice.transcriber import VoiceTranscriber
from ..deps import (
    get_analytics,
    get_question_retriever,
    get_rooms,
    get_session_manager,
    get_translation_service,
    get_tts_service,
    get_usage_caps,
    get_voice_transcriber,
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

logger = logging.getLogger(__name__)
router = APIRouter()


class QuestionRef(BaseModel):
    question_id: str = Field(max_length=128)


class AnswerRequest(QuestionRef):
    # Shown to every player on the reveal screen: invisible characters out,
    # and a blank answer is a 422, not an empty row.
    answer: Annotated[
        str,
        BeforeValidator(
            lambda v: clean_user_text(v).strip() if isinstance(v, str) else v
        ),
    ] = Field(
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


@router.post(
    "/rooms/{room_id}/answer/voice",
    response_model=RoomStateResponse,
    response_model_exclude_none=True,
)
@limiter.limit("30/minute")
async def answer_by_voice(
    request: Request,
    room_id: str,
    question_id: str = Form(max_length=128),
    audio: UploadFile = File(..., description="The spoken answer (16-bit WAV)"),
    rooms: Optional[RoomService] = Depends(get_rooms),
    question_retriever=Depends(get_question_retriever),
    voice_transcriber: VoiceTranscriber = Depends(get_voice_transcriber),
    usage_caps: UsageCaps = Depends(get_usage_caps),
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """Any player, typed-answer questions only (#249.5): the answer spoken,
    transcribed on the server exactly like a solo voice answer, then stored
    as if typed. It counts from when the recording ARRIVED: one that ends at
    the buzzer and lands within the grace is in time, however long the
    transcription takes. 409 = already answered / time up (checked before
    anything is paid for); 400 ``no_speech`` = nothing usable heard, nothing
    stored (the player may try again while time is left); 502 ``stt_error``
    = the recogniser failed, nothing stored."""
    received = rounds.now()
    subject_id, service = subject_or_401(subject), service_or_404(rooms)
    if not voice_transcriber.is_supported_format(audio.filename or ""):
        raise HTTPException(status_code=400, detail="Unsupported audio format")
    try:
        language = await service.play.hold_voice(
            room_id, subject_id, question_id, received
        )
    except RoomError as e:
        raise_http(e)
    analytics = get_analytics(request)

    def rejected(reason: str, chars: Optional[int] = None) -> None:
        # #240: why a voice answer was turned away, a count, never the words.
        analytics.emit(
            "transcription_failed",
            subject_id=subject_id,
            properties={
                "reason": reason,
                "question_id": question_id,
                "transcript_chars": chars,
                "multiplayer": True,
                "room_id": room_id,
            },
        )

    try:
        settings = get_settings()
        # No gate_voice_answer here, on purpose: in a game together only the
        # host pays per question (founder rule), so a player's spoken answer
        # never counts against their free monthly voice allowance. The solo
        # daily abuse caps below still apply per account.
        try:
            # #207.13: the solo daily caps, before transcription is paid for.
            await usage_caps.consume(
                subject_id,
                answer_attempts(question_id),
                1,
                settings.daily_cap_answer_attempts,
            )
            await usage_caps.consume(
                subject_id,
                STT_SECONDS,
                recording_seconds(audio.file),
                settings.daily_cap_stt_seconds,
            )
        except DailyCapExceeded as exc:
            rejected("daily_cap")
            raise exc.http_error() from exc
        question = await question_retriever.get(question_id)
        try:
            # The solo recogniser call: same model, size cap and language hint,
            # the question as context and no keyterms (an open question).
            result = await voice_transcriber.transcribe_with_quiz_context(
                audio_file=audio.file,
                filename=audio.filename,
                current_question=question.question if question else None,
                language=language,
            )
        except InvalidSubmission as exc:  # size/format: built from facts, safe
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except Exception as exc:
            rejected("stt_error")
            logger.warning("Room voice transcription failed: %s", type(exc).__name__)
            raise HTTPException(
                status_code=502,
                detail={"code": "stt_error", "message": "Transcription failed"},
            ) from exc
        text = clean_user_text(result.text).strip()[:200]
        if not result.is_valid(min_chars=2) or not text:
            user_text_log.info("Rejected room transcript: %r", result.text)
            rejected(result.rejection_code(2), len(result.text.strip()))
            raise HTTPException(
                status_code=400,
                detail={
                    "code": "no_speech",
                    "message": "No clear speech detected. Please try again.",
                },
            )
    except BaseException:
        await service.play.release_voice(room_id, subject_id, question_id)
        raise
    try:
        await service.play.answer(
            room_id,
            subject_id,
            question_id,
            text,
            received_at=received,
            route="voice",
        )
    except BaseException as e:
        # Any failure (a DB or grading error too) frees the hold, or every
        # player would wait out VOICE_PENDING_MAX for a transcript never stored.
        await service.play.release_voice(room_id, subject_id, question_id)
        if isinstance(e, RoomError):
            raise_http(e)
        raise
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
