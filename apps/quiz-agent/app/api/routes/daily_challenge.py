"""Daily challenge endpoints (#205 — player vs the crowd).

New endpoints only, so the live 1.0 app never sees a change. ``start`` hands
back an ordinary quiz session; the app then plays it through the existing
``/sessions/{id}/start`` and submit routes (server-side judging unchanged).
"""

from __future__ import annotations

import logging
from datetime import date, datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field

from quiz_shared.languages import servable_quiz_languages

from ...auth.identity import AuthSubject
from ...client_capabilities import CAPABILITIES_HEADER, parse_capabilities
from ...config import get_settings
from ...daily_challenge.schemas import DailyChallengeState
from ...daily_challenge.service import DailyChallengeService, DailySetUnavailable
from ...rate_limit import limiter
from ...session.manager import SessionManager
from ..deps import (
    SessionResponse,
    get_daily_challenge,
    get_session_manager,
    require_auth_or_grace,
    session_to_response,
)

logger = logging.getLogger(__name__)
router = APIRouter()


class DailyStartRequest(BaseModel):
    date: str = Field(description="The player's local date, YYYY-MM-DD")
    language: str = Field(description="Quiz language (en, sk, cs)")


class DailyStartResponse(BaseModel):
    state: DailyChallengeState
    session: Optional[SessionResponse] = Field(
        default=None,
        description="Set when there is something to play; null when already played",
    )


def _parse_day(value: str) -> date:
    """The player's local date: every time zone is within a day of UTC."""
    try:
        day = date.fromisoformat(value)
    except ValueError:
        raise HTTPException(status_code=422, detail="date must be YYYY-MM-DD")
    today = datetime.now(timezone.utc).date()
    if abs(day - today) > timedelta(days=1):
        raise HTTPException(status_code=422, detail="date is not today")
    return day


def _check_language(language: str) -> str:
    if language not in servable_quiz_languages():
        raise HTTPException(status_code=422, detail="unsupported language")
    return language


def _require(
    service: Optional[DailyChallengeService], subject: AuthSubject
) -> DailyChallengeService:
    if not get_settings().daily_challenge_enabled:
        raise HTTPException(status_code=404, detail="Daily challenge is off")
    if service is None:
        raise HTTPException(status_code=503, detail="Daily challenge unavailable")
    if not subject.subject_id:
        raise HTTPException(status_code=401, detail="Authentication required")
    return service


@router.get("/daily-challenge", response_model=DailyChallengeState)
@limiter.limit("60/minute")
async def get_daily_challenge_state(
    request: Request,
    date_: str = Query(alias="date"),
    language: str = Query(),
    service: Optional[DailyChallengeService] = Depends(get_daily_challenge),
    subject: AuthSubject = Depends(require_auth_or_grace),
) -> DailyChallengeState:
    """The Home card and round end: played or not, and the live crowd numbers."""
    svc = _require(service, subject)
    try:
        return await svc.state(
            subject.subject_id, _check_language(language), _parse_day(date_)
        )
    except DailySetUnavailable as e:
        logger.error("Daily challenge set unavailable: %s", e)
        raise HTTPException(status_code=503, detail="Daily challenge unavailable")


@router.post("/daily-challenge/start", response_model=DailyStartResponse)
@limiter.limit("10/minute")
async def start_daily_challenge(
    request: Request,
    body: DailyStartRequest,
    service: Optional[DailyChallengeService] = Depends(get_daily_challenge),
    subject: AuthSubject = Depends(require_auth_or_grace),
    session_manager: SessionManager = Depends(get_session_manager),
) -> DailyStartResponse:
    """One attempt per player per date: a finished challenge comes back as its
    result; an interrupted one resumes with the questions not yet answered."""
    svc = _require(service, subject)
    day = _parse_day(body.date)
    language = _check_language(body.language)
    try:
        play, remaining = await svc.begin(subject.subject_id, language, day)
        if not remaining:
            return DailyStartResponse(
                state=await svc.state(subject.subject_id, language, day)
            )
    except DailySetUnavailable as e:
        logger.error("Daily challenge set unavailable: %s", e)
        raise HTTPException(status_code=503, detail="Daily challenge unavailable")

    session = session_manager.create_session(
        max_questions=len(remaining),
        difficulty="random",
        user_id=subject.subject_id,
    )
    session.language = play.language
    if request.headers.get("X-Build-Channel") == "testflight":
        session.build_channel = "testflight"
    session.client_capabilities = parse_capabilities(
        request.headers.get(CAPABILITIES_HEADER)
    )
    session.daily_challenge_date = day.isoformat()
    session.fixed_question_ids = remaining
    session_manager.update_session(session)
    await svc.attach_session(play.id, session.session_id)
    return DailyStartResponse(
        state=await svc.state(subject.subject_id, language, day),
        session=session_to_response(session),
    )
