"""In-app beta feedback inbox (issue #109).

``POST /feedback`` — voice-dictated (or typed) tester feedback with optional
screenshot/audio/log attachments, landing in our own Postgres table (not
Sentry — no retention clock, all attachment types ours). ``GET /feedback`` +
``GET /feedback/{id}`` are admin-key-gated so the founder/agent can pull
submissions on demand without DB access.
"""

from __future__ import annotations

import base64
import json
import logging
import uuid

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from pydantic import BaseModel
from sqlalchemy import func, select

import sentry_sdk

from ..admin import verify_admin_key
from ..deps import get_auth_sessionmaker, require_auth_or_grace
from ...auth.identity import AuthSubject
from ...db.models import Feedback
from ...rate_limit import limiter

logger = logging.getLogger(__name__)
router = APIRouter()

MESSAGE_MAX_CHARS = 5000
SCREENSHOT_MAX_BYTES = 5 * 1024 * 1024
AUDIO_MAX_BYTES = 10 * 1024 * 1024
LOGS_MAX_BYTES = 1 * 1024 * 1024


class FeedbackSubmitResponse(BaseModel):
    """Response for a successful submission."""

    id: str


class FeedbackListItem(BaseModel):
    """One row in the admin list — no attachment bytes, only presence/size."""

    id: str
    user_id: str | None
    created_at: str
    message: str
    app_version: str | None
    has_screenshot: bool
    screenshot_size: int | None
    has_audio: bool
    audio_size: int | None
    has_logs: bool
    logs_size: int | None


class FeedbackListResponse(BaseModel):
    total: int
    items: list[FeedbackListItem]


class FeedbackDetail(BaseModel):
    """Full row, attachments included as base64 (admin-only, beta scale)."""

    id: str
    user_id: str | None
    created_at: str
    message: str
    metadata: dict | None
    app_version: str | None
    logs: str | None
    screenshot_base64: str | None
    screenshot_content_type: str | None
    audio_base64: str | None
    audio_content_type: str | None


async def _read_capped(upload: UploadFile, *, max_bytes: int, field: str) -> bytes:
    data = await upload.read()
    if len(data) > max_bytes:
        raise HTTPException(
            status_code=413,
            detail=f"{field} exceeds the {max_bytes} byte limit",
        )
    return data


@router.post("/feedback", response_model=FeedbackSubmitResponse, status_code=201)
@limiter.limit("5/minute")
async def submit_feedback(
    request: Request,
    message: str = Form(...),
    metadata: str | None = Form(default=None),
    app_version: str | None = Form(default=None),
    screenshot: UploadFile | None = File(default=None),
    audio: UploadFile | None = File(default=None),
    logs: UploadFile | None = File(default=None),
    auth: AuthSubject = Depends(require_auth_or_grace),
    sessionmaker=Depends(get_auth_sessionmaker),
):
    """Insert one feedback row. Auth = ``require_auth_or_grace`` (same gate as
    session routes); rate-limited 5/min; every size cap is enforced server-side
    with a 413 on breach, before anything is written."""
    if sessionmaker is None:
        raise HTTPException(status_code=503, detail="Feedback storage unavailable")

    if len(message) > MESSAGE_MAX_CHARS:
        raise HTTPException(
            status_code=413,
            detail=f"message exceeds the {MESSAGE_MAX_CHARS} character limit",
        )

    metadata_dict = None
    if metadata:
        try:
            metadata_dict = json.loads(metadata)
        except json.JSONDecodeError:
            raise HTTPException(status_code=400, detail="metadata must be valid JSON")

    screenshot_bytes = None
    screenshot_content_type = None
    if screenshot is not None:
        screenshot_bytes = await _read_capped(
            screenshot, max_bytes=SCREENSHOT_MAX_BYTES, field="screenshot"
        )
        screenshot_content_type = screenshot.content_type

    audio_bytes = None
    audio_content_type = None
    if audio is not None:
        audio_bytes = await _read_capped(
            audio, max_bytes=AUDIO_MAX_BYTES, field="audio"
        )
        audio_content_type = audio.content_type

    logs_text = None
    if logs is not None:
        logs_bytes = await _read_capped(logs, max_bytes=LOGS_MAX_BYTES, field="logs")
        logs_text = logs_bytes.decode("utf-8", errors="replace")

    row = Feedback(
        id=uuid.uuid4(),
        user_id=auth.subject_id,
        message=message,
        metadata_=metadata_dict,
        app_version=app_version,
        logs=logs_text,
        screenshot=screenshot_bytes,
        screenshot_content_type=screenshot_content_type,
        audio=audio_bytes,
        audio_content_type=audio_content_type,
    )
    async with sessionmaker() as session:
        session.add(row)
        await session.commit()
        await session.refresh(row)

    if sentry_sdk.get_client().is_active():
        sentry_sdk.capture_message(
            f"feedback.received id={row.id} message={message[:100]!r}",
            level="info",
        )

    return FeedbackSubmitResponse(id=str(row.id))


@router.get("/feedback", response_model=FeedbackListResponse)
async def list_feedback(
    sessionmaker=Depends(get_auth_sessionmaker),
    _: str = Depends(verify_admin_key),
):
    """Newest-first list, no attachment bytes — admin-key gated (#91 pattern)."""
    if sessionmaker is None:
        raise HTTPException(status_code=503, detail="Feedback storage unavailable")

    stmt = select(
        Feedback.id,
        Feedback.user_id,
        Feedback.created_at,
        Feedback.message,
        Feedback.app_version,
        func.length(Feedback.screenshot).label("screenshot_size"),
        func.length(Feedback.audio).label("audio_size"),
        func.length(Feedback.logs).label("logs_size"),
    ).order_by(Feedback.created_at.desc())

    async with sessionmaker() as session:
        rows = (await session.execute(stmt)).all()

    items = [
        FeedbackListItem(
            id=str(r.id),
            user_id=r.user_id,
            created_at=r.created_at.isoformat(),
            message=r.message,
            app_version=r.app_version,
            has_screenshot=r.screenshot_size is not None,
            screenshot_size=r.screenshot_size,
            has_audio=r.audio_size is not None,
            audio_size=r.audio_size,
            has_logs=r.logs_size is not None,
            logs_size=r.logs_size,
        )
        for r in rows
    ]
    return FeedbackListResponse(total=len(items), items=items)


@router.get("/feedback/{feedback_id}", response_model=FeedbackDetail)
async def get_feedback_detail(
    feedback_id: str,
    sessionmaker=Depends(get_auth_sessionmaker),
    _: str = Depends(verify_admin_key),
):
    """Full row incl. attachments, base64-encoded — admin-key gated."""
    if sessionmaker is None:
        raise HTTPException(status_code=503, detail="Feedback storage unavailable")

    try:
        row_id = uuid.UUID(feedback_id)
    except ValueError:
        raise HTTPException(status_code=404, detail="Feedback not found")

    async with sessionmaker() as session:
        row = await session.get(Feedback, row_id)

    if row is None:
        raise HTTPException(status_code=404, detail="Feedback not found")

    return FeedbackDetail(
        id=str(row.id),
        user_id=row.user_id,
        created_at=row.created_at.isoformat(),
        message=row.message,
        metadata=row.metadata_,
        app_version=row.app_version,
        logs=row.logs,
        screenshot_base64=(
            base64.b64encode(row.screenshot).decode() if row.screenshot else None
        ),
        screenshot_content_type=row.screenshot_content_type,
        audio_base64=base64.b64encode(row.audio).decode() if row.audio else None,
        audio_content_type=row.audio_content_type,
    )
