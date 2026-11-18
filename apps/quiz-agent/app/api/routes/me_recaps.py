"""``GET /api/v1/me/recaps`` and ``POST /api/v1/me/recaps/{id}/seen`` (#213.3)."""

from __future__ import annotations

import uuid
from datetime import date, datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import select

from ...auth.account_service import linked_anon_ids
from ...auth.identity import AuthSubject
from ...db.models import PlayerRecap
from ...player_stats.recaps import ensure_recaps
from ...rate_limit import limiter
from ..deps import get_auth_sessionmaker, require_auth_or_grace

router = APIRouter()


class RecapOut(BaseModel):
    id: str
    # Plain strings, not enums: a new recap kind must not break live builds.
    kind: str
    period_start: date
    created_at: datetime
    seen: bool
    schema_version: int
    payload: dict


class RecapsResponse(BaseModel):
    recaps: list[RecapOut]


def _require_player(subject: AuthSubject, sessionmaker) -> str:
    """Same rules as /me/stats: a verified bearer, never the grace fallback."""
    if not subject.authenticated or not subject.subject_id:
        raise HTTPException(status_code=401, detail="Authentication required")
    if sessionmaker is None:
        raise HTTPException(status_code=503, detail="Recaps unavailable")
    return subject.subject_id


@router.get("/me/recaps", response_model=RecapsResponse)
@limiter.limit("30/minute")
async def get_my_recaps(
    request: Request,
    subject: AuthSubject = Depends(require_auth_or_grace),
    sessionmaker=Depends(get_auth_sessionmaker),
) -> RecapsResponse:
    """Create any recap the player has earned, then list all of them, across the
    account and its linked anonymous ids. For a period held by two identities the
    oldest (already seen) snapshot wins."""
    caller = _require_player(subject, sessionmaker)
    async with sessionmaker() as session:
        ids = [caller, *await linked_anon_ids(session, caller)]
        await ensure_recaps(session, caller, ids, datetime.now(timezone.utc))
        await session.commit()
        rows = (
            (
                await session.execute(
                    select(PlayerRecap)
                    .where(PlayerRecap.subject_id.in_(ids))
                    .order_by(PlayerRecap.created_at)
                )
            )
            .scalars()
            .all()
        )
    unique: dict[tuple[str, date], PlayerRecap] = {}
    for r in rows:
        unique.setdefault((r.kind, r.period_start), r)
    ordered = sorted(
        unique.values(), key=lambda r: (r.period_start, r.created_at), reverse=True
    )
    return RecapsResponse(
        recaps=[
            RecapOut(
                id=str(r.id),
                kind=r.kind,
                period_start=r.period_start,
                created_at=r.created_at,
                seen=r.seen_at is not None,
                schema_version=r.schema_version,
                payload=r.payload,
            )
            for r in ordered
        ]
    )


@router.post("/me/recaps/{recap_id}/seen", status_code=204)
@limiter.limit("60/minute")
async def mark_recap_seen(
    request: Request,
    recap_id: str,
    subject: AuthSubject = Depends(require_auth_or_grace),
    sessionmaker=Depends(get_auth_sessionmaker),
) -> None:
    """Set ``seen_at`` once; a recap of someone else (or unknown) is a 404."""
    caller = _require_player(subject, sessionmaker)
    try:
        rid = uuid.UUID(recap_id)
    except ValueError:
        raise HTTPException(status_code=404, detail="Recap not found") from None
    async with sessionmaker() as session:
        ids = [caller, *await linked_anon_ids(session, caller)]
        recap = (
            await session.execute(
                select(PlayerRecap).where(
                    PlayerRecap.id == rid, PlayerRecap.subject_id.in_(ids)
                )
            )
        ).scalar_one_or_none()
        if recap is None:
            raise HTTPException(status_code=404, detail="Recap not found")
        if recap.seen_at is None:
            recap.seen_at = datetime.now(timezone.utc)
            await session.commit()
