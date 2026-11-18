"""``GET /api/v1/me/stats`` — the player's stat cards (#213)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from ...auth.account_service import linked_anon_ids
from ...auth.identity import AuthSubject
from ...player_stats.service import compute_player_stats
from ...rate_limit import limiter
from ..deps import get_auth_sessionmaker, require_auth_or_grace

router = APIRouter()


class StatProgress(BaseModel):
    current: int
    target: int
    # Plain strings, not enums: a new unit or card kind must not break live builds.
    unit: str


class StatCard(BaseModel):
    kind: str
    state: str  # "locked" | "unlocked"
    progress: StatProgress
    data: dict


class FirstRecapProgress(BaseModel):
    answers: int
    answers_target: int
    days: int
    days_target: int


class PlayerStatsResponse(BaseModel):
    cards: list[StatCard]
    first_recap_progress: FirstRecapProgress


@router.get("/me/stats", response_model=PlayerStatsResponse)
@limiter.limit("30/minute")
async def get_my_stats(
    request: Request,
    subject: AuthSubject = Depends(require_auth_or_grace),
    sessionmaker=Depends(get_auth_sessionmaker),
) -> PlayerStatsResponse:
    """Cards for the caller and, for an account, its linked anonymous ids.

    A verified bearer is required: stats belong to one identity, and the
    grace-window ``user_id`` fallback is unauthenticated, so it gets a 401."""
    if not subject.authenticated or not subject.subject_id:
        raise HTTPException(status_code=401, detail="Authentication required")
    if sessionmaker is None:
        raise HTTPException(status_code=503, detail="Stats unavailable")
    async with sessionmaker() as session:
        ids = [subject.subject_id, *await linked_anon_ids(session, subject.subject_id)]
        return PlayerStatsResponse(**await compute_player_stats(session, ids))
