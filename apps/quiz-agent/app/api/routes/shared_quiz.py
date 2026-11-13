"""Share a quiz by link (#232 task 232.1).

New endpoints only, behind the ``shared_quiz_enabled`` app switch (404 when
off), so live builds never see a change. A started share hands back an ordinary
quiz session the app plays through the existing ``/sessions/{id}`` routes.
No payload here ever carries a question or an answer.
"""

from __future__ import annotations

from datetime import date
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Path, Request
from pydantic import BaseModel, Field

from ... import app_switches
from ...auth.identity import AuthSubject
from ...client_capabilities import CAPABILITIES_HEADER, parse_capabilities
from ...config import get_settings
from ...db.models import SharedQuiz
from ...rate_limit import limiter
from ...shared_quiz.ranking import RankedPlayer
from ...shared_quiz.service import SharedQuizService, ShareError
from ..deps import (
    SessionResponse,
    get_auth_sessionmaker,
    get_shared_quiz,
    require_auth_or_grace,
    session_to_response,
)
from .daily_challenge import _parse_day
from .rooms import _PlayerName

router = APIRouter()

Token = Path(min_length=8, max_length=64, pattern=r"^[A-Za-z0-9_-]+$")


class CreateShareRequest(BaseModel):
    """``session_id``: the caller's finished round, daily challenge or pack
    session. ``pack_id`` (without a session): the caller's finished pack."""

    session_id: Optional[str] = Field(default=None, max_length=64)
    pack_id: Optional[str] = Field(default=None, max_length=64)
    display_name: Optional[_PlayerName] = None


class ShareInfo(BaseModel):
    kind: str = Field(description="round | daily | pack")
    language: str
    title: Optional[str] = Field(default=None, description="The pack's name")
    categories: List[str] = Field(default_factory=list)
    question_count: int


class ShareResponse(ShareInfo):
    token: str


class StartShareRequest(BaseModel):
    date: Optional[str] = Field(
        default=None,
        description="The player's local date (YYYY-MM-DD): a daily link opened "
        "the same day starts the player's own daily challenge",
    )
    display_name: Optional[_PlayerName] = None


class StartShareResponse(BaseModel):
    kind: str
    session: Optional[SessionResponse] = Field(
        default=None, description="Null when already_played"
    )
    already_played: bool = False


class ShareResultsResponse(ShareInfo):
    players: List[RankedPlayer]


class SharePreview(BaseModel):
    kind: str
    language: str
    title: Optional[str] = None
    categories: List[str] = Field(default_factory=list)


def _info(share: SharedQuiz) -> dict:
    return {
        "kind": share.kind,
        "language": share.language,
        "title": share.title,
        "categories": share.topic.split(",") if share.topic else [],
        "question_count": len(share.question_ids),
    }


async def _service(
    request: Request, service: Optional[SharedQuizService]
) -> SharedQuizService:
    on = await app_switches.is_on(
        get_settings(), get_auth_sessionmaker(request), "shared_quiz_enabled"
    )
    if not on or service is None:
        raise HTTPException(status_code=404, detail="Not found")
    return service


def _subject(subject: AuthSubject) -> str:
    if not subject.subject_id:
        raise HTTPException(status_code=401, detail="Authentication required")
    return subject.subject_id


def _raise(e: ShareError):
    raise HTTPException(
        status_code=e.status, detail={"code": e.code, "message": e.message}
    )


@router.post("/shared-quizzes", response_model=ShareResponse)
@limiter.limit("10/minute")
async def create_share(
    request: Request,
    body: CreateShareRequest,
    service: Optional[SharedQuizService] = Depends(get_shared_quiz),
    subject: AuthSubject = Depends(require_auth_or_grace),
) -> ShareResponse:
    svc = await _service(request, service)
    try:
        share = await svc.create(
            _subject(subject),
            session_id=body.session_id,
            pack_id=body.pack_id,
            name=body.display_name,
        )
    except ShareError as e:
        _raise(e)
    return ShareResponse(token=share.token, **_info(share))


@router.post("/shared-quizzes/{token}/start", response_model=StartShareResponse)
@limiter.limit("10/minute")
async def start_share(
    request: Request,
    body: StartShareRequest,
    token: str = Token,
    service: Optional[SharedQuizService] = Depends(get_shared_quiz),
    subject: AuthSubject = Depends(require_auth_or_grace),
) -> StartShareResponse:
    svc = await _service(request, service)
    day: Optional[date] = _parse_day(body.date) if body.date else None
    try:
        outcome = await svc.start(
            token,
            _subject(subject),
            day=day,
            name=body.display_name,
            # Same whitelist as session creation: only the exact literal widens
            # the review gate to TestFlight's pending questions.
            build_channel="testflight"
            if request.headers.get("X-Build-Channel") == "testflight"
            else None,
            capabilities=parse_capabilities(request.headers.get(CAPABILITIES_HEADER)),
        )
    except ShareError as e:
        _raise(e)
    return StartShareResponse(
        kind=outcome.share.kind,
        session=session_to_response(outcome.session) if outcome.session else None,
        already_played=outcome.already_played,
    )


@router.get("/shared-quizzes/{token}/results", response_model=ShareResultsResponse)
@limiter.limit("60/minute")
async def share_results(
    request: Request,
    token: str = Token,
    service: Optional[SharedQuizService] = Depends(get_shared_quiz),
    subject: AuthSubject = Depends(require_auth_or_grace),
) -> ShareResultsResponse:
    """Sender and everyone who finished it, best first."""
    svc = await _service(request, service)
    try:
        share, players = await svc.ranking(token, _subject(subject))
    except ShareError as e:
        _raise(e)
    return ShareResultsResponse(players=players, **_info(share))


@router.get("/shared-quizzes/{token}", response_model=SharePreview)
@limiter.limit("60/minute")
async def share_preview(
    request: Request,
    token: str = Token,
    service: Optional[SharedQuizService] = Depends(get_shared_quiz),
) -> SharePreview:
    """Public and read-only, for the website's play page: what the link is,
    never its questions or players."""
    svc = await _service(request, service)
    try:
        share = await svc.preview(token)
    except ShareError as e:
        _raise(e)
    info = _info(share)
    info.pop("question_count")
    return SharePreview(**info)
