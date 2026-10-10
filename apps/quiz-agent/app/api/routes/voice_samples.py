"""Car answer recordings for replay tests (issue #197, track 197.2).

``POST /voice-samples`` — a TestFlight/debug build sends every answer
recording (raw 16 kHz WAV) plus its sidecar JSON while the "Save answer
recordings" switch is on. Not a product feature. Who may upload depends on
``VOICE_SAMPLE_UPLOAD_MODE``:

- ``allowlist`` (default): only bearer-verified subjects on the
  ``VOICE_SAMPLE_UPLOAD_USER_IDS`` allowlist (the founder).
- ``consented`` (founder decision 2026-10-10): additionally any bearer-verified
  subject (account or anonymous device identity) whose app declares that the
  tester said yes to the one-time beta consent question (``consent=true``).

Everyone else gets 403 before anything is validated or stored. Every uploader
is capped at ``VOICE_SAMPLE_DAILY_CAP`` recordings per rolling 24 h (429), so a
buggy client cannot flood the bucket.

``GET /voice-samples`` — admin-key gated list with presigned audio URLs, read
by ``scripts/voice_replay.py`` (and later the labeling page, track 197.3).
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import re
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse
from fastapi.routing import APIRoute
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError

from ...auth.identity import AuthSubject
from ...db.models import VoiceSample
from ...rate_limit import limiter
from ...voice.sample_storage import (
    KEY_PREFIX,
    StorageNotConfigured,
    VoiceSampleStorage,
    get_voice_sample_storage,
)
from ..admin import verify_admin_key
from ..deps import get_auth_sessionmaker, require_auth_or_grace

logger = logging.getLogger(__name__)

ALLOWLIST_ENV = "VOICE_SAMPLE_UPLOAD_USER_IDS"
MODE_ENV = "VOICE_SAMPLE_UPLOAD_MODE"
DAILY_CAP_ENV = "VOICE_SAMPLE_DAILY_CAP"
# A beta tester answers well under 100 questions a day; 300 only stops a client
# stuck in an upload loop.
DEFAULT_DAILY_CAP = 300
# The app caps a capture at the dead-air cap (~15 s ≈ 0.5 MB at 16 kHz mono);
# 5 MB leaves room for a long answer and nothing more.
AUDIO_MAX_BYTES = 5 * 1024 * 1024
SIDECAR_MAX_BYTES = 64 * 1024
# Whole multipart body: audio + sidecar + stamp + part headers.
BODY_MAX_BYTES = AUDIO_MAX_BYTES + SIDECAR_MAX_BYTES + 64 * 1024


class _BodyCapRoute(APIRoute):
    """FastAPI parses the multipart body (spooling parts to temp disk) BEFORE
    any dependency runs, so the allowlist cannot stop an anonymous caller
    from streaming a huge part. This check runs first, on the headers alone:
    a POST must declare its length and stay under the cap. The ASGI server
    never reads past a declared Content-Length."""

    def get_route_handler(self):
        handler = super().get_route_handler()

        async def capped(request: Request):
            if request.method == "POST":
                declared = request.headers.get("content-length")
                if declared is None or not declared.isdigit():
                    return JSONResponse(
                        {"detail": "Content-Length required"}, status_code=411
                    )
                if int(declared) > BODY_MAX_BYTES:
                    return JSONResponse(
                        {"detail": "request body too large"}, status_code=413
                    )
            return await handler(request)

        return capped


router = APIRouter(route_class=_BodyCapRoute)
WAV_CONTENT_TYPES = {"audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave"}
STAMP_PATTERN = re.compile(r"^\d{8}-\d{6}-\d{3}$")
_READ_CHUNK_BYTES = 64 * 1024


def upload_allowlist() -> set[str]:
    """Subject ids allowed to upload, read live so a secret change applies on
    the next request (and tests can monkeypatch)."""
    raw = os.getenv(ALLOWLIST_ENV, "")
    return {part.strip() for part in raw.split(",") if part.strip()}


def consented_mode() -> bool:
    """True only for the exact value ``consented``; anything else (unset, a
    typo) keeps the founder-only allowlist, so a bad secret fails closed."""
    return os.getenv(MODE_ENV, "").strip().lower() == "consented"


def daily_cap() -> int:
    raw = os.getenv(DAILY_CAP_ENV, "").strip()
    return int(raw) if raw.isdigit() else DEFAULT_DAILY_CAP


def require_sample_uploader(
    subject: AuthSubject = Depends(require_auth_or_grace),
    consent: bool = Form(False),
) -> AuthSubject:
    """A verified bearer that is allowlisted, or (consented mode) one whose app
    declares the tester's consent. The legacy grace pass-through
    (``authenticated=False``) never qualifies."""
    allowed = subject.authenticated and (
        subject.subject_id in upload_allowlist() or (consented_mode() and consent)
    )
    if not allowed:
        # The subject id in the log is how the founder finds his own id to add
        # to the allowlist; it is an opaque anon/account id, not personal data.
        logger.info(
            "voice sample upload refused for subject=%s (authenticated=%s)",
            subject.subject_id,
            subject.authenticated,
        )
        raise HTTPException(status_code=403, detail="Voice sample upload not enabled")
    return subject


class VoiceSampleUploadResponse(BaseModel):
    id: str
    duplicate: bool = False


class VoiceSampleItem(BaseModel):
    id: str
    user_id: str
    session_id: str | None
    question_id: str | None
    language: str | None
    created_at: str
    audio_bytes: int
    sidecar: dict
    label: dict | None
    audio_url: str


class VoiceSampleListResponse(BaseModel):
    total: int
    items: list[VoiceSampleItem]


async def _read_capped(upload: UploadFile, *, max_bytes: int, field: str) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while chunk := await upload.read(_READ_CHUNK_BYTES):
        total += len(chunk)
        if total > max_bytes:
            raise HTTPException(
                status_code=413, detail=f"{field} exceeds the {max_bytes} byte limit"
            )
        chunks.append(chunk)
    return b"".join(chunks)


def is_wav(data: bytes) -> bool:
    """RIFF/WAVE container — the header the app's WAVEncoder writes."""
    return len(data) > 44 and data[0:4] == b"RIFF" and data[8:12] == b"WAVE"


def sample_key(user_id: str, stamp: str) -> str:
    """Deterministic per (user, recording): a retried upload whose response was
    lost maps to the same key, so it is answered as a duplicate instead of
    stored twice. The user part is hashed so bucket listings carry no ids."""
    user_part = hashlib.sha256(user_id.encode()).hexdigest()[:16]
    return f"{KEY_PREFIX}/{user_part}/{stamp}.wav"


def _optional_text(sidecar: dict, key: str) -> str | None:
    value = sidecar.get(key)
    return str(value) if value not in (None, "") else None


@router.post(
    "/voice-samples", response_model=VoiceSampleUploadResponse, status_code=201
)
@limiter.limit("60/minute")
async def upload_voice_sample(
    request: Request,
    stamp: str = Form(...),
    sidecar: str = Form(...),
    audio: UploadFile = File(...),
    subject: AuthSubject = Depends(require_sample_uploader),
    sessionmaker=Depends(get_auth_sessionmaker),
    storage: VoiceSampleStorage = Depends(get_voice_sample_storage),
):
    if not STAMP_PATTERN.match(stamp):
        raise HTTPException(status_code=400, detail="stamp must be yyyyMMdd-HHmmss-SSS")
    if len(sidecar.encode()) > SIDECAR_MAX_BYTES:
        raise HTTPException(status_code=413, detail="sidecar too large")
    try:
        sidecar_dict = json.loads(sidecar)
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="sidecar must be valid JSON")
    if not isinstance(sidecar_dict, dict):
        raise HTTPException(status_code=400, detail="sidecar must be a JSON object")

    content_type = (audio.content_type or "").split(";")[0].strip().lower()
    if content_type not in WAV_CONTENT_TYPES:
        raise HTTPException(status_code=415, detail="audio must be audio/wav")
    audio_bytes = await _read_capped(audio, max_bytes=AUDIO_MAX_BYTES, field="audio")
    if not is_wav(audio_bytes):
        raise HTTPException(status_code=415, detail="audio is not a RIFF/WAVE file")

    if sessionmaker is None:
        raise HTTPException(status_code=503, detail="Voice sample storage unavailable")

    key = sample_key(subject.subject_id, stamp)
    existing = await _existing_id(sessionmaker, key)
    if existing is not None:
        return VoiceSampleUploadResponse(id=str(existing), duplicate=True)

    # Checked after the duplicate lookup: a retry of a stored recording is
    # still answered as a duplicate, so the app can delete its copy.
    if await _uploads_last_day(sessionmaker, subject.subject_id) >= daily_cap():
        raise HTTPException(status_code=429, detail="Daily voice sample limit reached")

    row = VoiceSample(
        id=uuid.uuid4(),
        user_id=subject.subject_id,
        session_id=_optional_text(sidecar_dict, "sessionId"),
        question_id=_optional_text(sidecar_dict, "questionId"),
        language=_optional_text(sidecar_dict, "language"),
        sidecar=sidecar_dict,
        r2_key=key,
        audio_bytes=len(audio_bytes),
    )
    # Row first (flushed, uncommitted), then the audio, then the commit: a
    # recording is never in R2 without a row the erasure can find. If the
    # commit fails after the put, the object is removed again.
    async with sessionmaker() as session:
        session.add(row)
        try:
            await session.flush()
        except IntegrityError:
            # A concurrent retry of the same recording won the unique r2_key.
            await session.rollback()
            existing = await _existing_id(sessionmaker, key)
            return VoiceSampleUploadResponse(id=str(existing), duplicate=True)
        try:
            await asyncio.to_thread(storage.put, key, audio_bytes, "audio/wav")
        except StorageNotConfigured as exc:
            logger.error("voice sample upload: %s", exc)
            raise HTTPException(
                status_code=503, detail="Voice sample storage not configured"
            )
        try:
            await session.commit()
        except Exception:
            logger.exception("voice sample row commit failed; removing %s from R2", key)
            await _remove_orphan(storage, key)
            raise HTTPException(status_code=503, detail="Voice sample not stored")
    return VoiceSampleUploadResponse(id=str(row.id))


async def _existing_id(sessionmaker, key: str):
    async with sessionmaker() as session:
        return (
            await session.execute(
                select(VoiceSample.id).where(VoiceSample.r2_key == key)
            )
        ).scalar_one_or_none()


async def _uploads_last_day(sessionmaker, user_id: str) -> int:
    since = datetime.now(timezone.utc) - timedelta(days=1)
    async with sessionmaker() as session:
        return (
            await session.execute(
                select(func.count())
                .select_from(VoiceSample)
                .where(VoiceSample.user_id == user_id, VoiceSample.created_at >= since)
            )
        ).scalar_one()


async def _remove_orphan(storage: VoiceSampleStorage, key: str) -> None:
    try:
        await asyncio.to_thread(storage.delete, [key])
    except Exception:
        # Loud: this object now exists without a row, so account erasure
        # cannot reach it. Fix by hand (key in the log line).
        logger.exception("ORPHANED voice sample in R2 (no DB row): %s", key)


@router.get("/voice-samples", response_model=VoiceSampleListResponse)
async def list_voice_samples(
    limit: int = 500,
    sessionmaker=Depends(get_auth_sessionmaker),
    storage: VoiceSampleStorage = Depends(get_voice_sample_storage),
    _: str = Depends(verify_admin_key),
):
    """Newest first, each with a 1-hour presigned audio URL — admin-key gated."""
    if sessionmaker is None:
        raise HTTPException(status_code=503, detail="Voice sample storage unavailable")
    stmt = (
        select(VoiceSample)
        .order_by(VoiceSample.created_at.desc())
        .limit(max(1, min(limit, 2000)))
    )
    async with sessionmaker() as session:
        rows = (await session.execute(stmt)).scalars().all()
    try:
        items = [
            VoiceSampleItem(
                id=str(r.id),
                user_id=r.user_id,
                session_id=r.session_id,
                question_id=r.question_id,
                language=r.language,
                created_at=r.created_at.isoformat(),
                audio_bytes=r.audio_bytes,
                sidecar=r.sidecar,
                label=r.label,
                audio_url=storage.presigned_url(r.r2_key),
            )
            for r in rows
        ]
    except StorageNotConfigured as exc:
        logger.error("voice sample list: %s", exc)
        raise HTTPException(
            status_code=503, detail="Voice sample storage not configured"
        )
    return VoiceSampleListResponse(total=len(items), items=items)
