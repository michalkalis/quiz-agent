"""Daily challenge endpoints (#205 — player vs the crowd).

New endpoints only, so the live 1.0 app never sees a change. ``start`` hands
back an ordinary quiz session; the app then plays it through the existing
``/sessions/{id}/start`` and submit routes (server-side judging unchanged).
"""

from __future__ import annotations

import logging
from datetime import date, datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Path, Query, Request, Response
from pydantic import BaseModel, Field

from quiz_shared.languages import servable_quiz_languages

from ...analytics.recorder import AnalyticsRecorder
from ...auth.identity import AuthSubject
from ...client_capabilities import CAPABILITIES_HEADER, parse_capabilities
from ...daily_challenge.crew import CrewNotFound, DailyCrewService
from ...daily_challenge.gate import daily_challenge_on
from ...daily_challenge.schemas import DailyChallengeState, DailyCrew
from ...daily_challenge.service import DailyChallengeService, DailySetUnavailable
from ...rate_limit import limiter
from ...session.manager import SessionManager
from ..deps import (
    SessionResponse,
    get_analytics,
    get_auth_sessionmaker,
    get_daily_challenge,
    get_daily_crew,
    get_session_manager,
    require_auth_or_grace,
    session_to_response,
)

logger = logging.getLogger(__name__)
router = APIRouter()


class DailyStartRequest(BaseModel):
    date: str = Field(description="The player's local date, YYYY-MM-DD")
    language: str = Field(description="Quiz language (en, sk, cs)")
    utc_offset_minutes: Optional[int] = Field(
        default=None,
        ge=-720,
        le=840,
        description="The player's UTC offset; the day's bonus ends at their midnight",
    )


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


async def _require(
    request: Request,
    sessionmaker,
    service: Optional[DailyChallengeService],
    subject: AuthSubject,
) -> DailyChallengeService:
    if not await daily_challenge_on(request, sessionmaker):
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
    sessionmaker=Depends(get_auth_sessionmaker),
) -> DailyChallengeState:
    """The Home card and round end: played or not, and the live crowd numbers."""
    svc = await _require(request, sessionmaker, service, subject)
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
    sessionmaker=Depends(get_auth_sessionmaker),
) -> DailyStartResponse:
    """One attempt per player per date: a finished challenge comes back as its
    result; an interrupted one resumes with the questions not yet answered."""
    svc = await _require(request, sessionmaker, service, subject)
    day = _parse_day(body.date)
    language = _check_language(body.language)
    try:
        play, remaining = await svc.begin(
            subject.subject_id, language, day, body.utc_offset_minutes
        )
        if not remaining:
            return DailyStartResponse(
                state=await svc.state(subject.subject_id, language, day)
            )
    except DailySetUnavailable as e:
        logger.error("Daily challenge set unavailable: %s", e)
        raise HTTPException(status_code=503, detail="Daily challenge unavailable")

    session = await session_manager.create_session(
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
    await session_manager.update_session(session)
    await svc.attach_session(play.id, session.session_id)
    return DailyStartResponse(
        state=await svc.state(subject.subject_id, language, day),
        session=session_to_response(session),
    )


@router.get("/daily-challenge/crew", response_model=DailyCrew)
@limiter.limit("60/minute")
async def get_daily_crew_table(
    request: Request,
    date_: str = Query(alias="date"),
    language: str = Query(),
    service: Optional[DailyChallengeService] = Depends(get_daily_challenge),
    crew: Optional[DailyCrewService] = Depends(get_daily_crew),
    subject: AuthSubject = Depends(require_auth_or_grace),
    sessionmaker=Depends(get_auth_sessionmaker),
    analytics: AnalyticsRecorder = Depends(get_analytics),
) -> DailyCrew:
    """#239 the week's crew: everyone the player swapped a daily link with,
    by rarity points from Monday to ``date``. Empty ``members`` = no crew."""
    await _require(request, sessionmaker, service, subject)
    if crew is None:
        raise HTTPException(status_code=503, detail="Daily challenge unavailable")
    table = await crew.crew(
        subject.subject_id, _parse_day(date_), _check_language(language)
    )
    analytics.emit(
        "daily_crew_viewed",
        subject_id=subject.subject_id,
        properties={"members": max(0, len(table.members) - 1)},
    )
    return table


@router.delete("/daily-challenge/crew/{member_id}", status_code=204)
@limiter.limit("10/minute")
async def remove_daily_crew_member(
    request: Request,
    member_id: str = Path(max_length=64),
    service: Optional[DailyChallengeService] = Depends(get_daily_challenge),
    crew: Optional[DailyCrewService] = Depends(get_daily_crew),
    subject: AuthSubject = Depends(require_auth_or_grace),
    sessionmaker=Depends(get_auth_sessionmaker),
    analytics: AnalyticsRecorder = Depends(get_analytics),
) -> Response:
    """#239 take one person out of the crew; both stop seeing each other."""
    await _require(request, sessionmaker, service, subject)
    if crew is None:
        raise HTTPException(status_code=503, detail="Daily challenge unavailable")
    try:
        await crew.remove(subject.subject_id, member_id)
    except CrewNotFound:
        raise HTTPException(status_code=404, detail="Not in your crew")
    analytics.emit("daily_crew_member_removed", subject_id=subject.subject_id)
    return Response(status_code=204)
