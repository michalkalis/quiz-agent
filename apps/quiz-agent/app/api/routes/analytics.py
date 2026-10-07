"""Client analytics ingest (issue #51).

``POST /analytics/events`` — the app posts small batches of the client-only
events the server cannot observe itself (paywall views, voice commands, …).
Names and property keys are allowlisted in ``app.analytics.taxonomy``; anything
else is dropped, not stored. The subject comes from the bearer, never the body.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from fastapi import APIRouter, Depends, Header, Request
from pydantic import BaseModel, Field

from ...analytics.recorder import AnalyticsRecorder, ClientEvent
from ...auth.identity import AuthSubject
from ...rate_limit import limiter
from ..deps import get_analytics, require_auth_or_grace

router = APIRouter()

MAX_BATCH = 50


class ClientEventIn(BaseModel):
    name: str = Field(max_length=64)
    occurred_at: datetime | None = None
    session_id: str | None = Field(default=None, max_length=64)
    properties: dict[str, Any] = Field(default_factory=dict)


class EventBatchIn(BaseModel):
    events: list[ClientEventIn] = Field(max_length=MAX_BATCH)


class EventBatchOut(BaseModel):
    accepted: int
    dropped: int


@router.post("/analytics/events", response_model=EventBatchOut)
@limiter.limit("30/minute")
async def ingest_events(
    request: Request,
    body: EventBatchIn,
    x_app_version: str | None = Header(default=None, max_length=32),
    auth: AuthSubject = Depends(require_auth_or_grace),
    analytics: AnalyticsRecorder = Depends(get_analytics),
):
    accepted, dropped = await analytics.record_client_batch(
        [
            ClientEvent(e.name, e.occurred_at, e.session_id, e.properties)
            for e in body.events
        ],
        subject_id=auth.subject_id,
        app_version=x_app_version,
    )
    return EventBatchOut(accepted=accepted, dropped=dropped)
