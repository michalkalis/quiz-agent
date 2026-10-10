"""Car answer recordings for replay tests (issue #197, track 197.2).

``POST /voice-samples`` — the founder's TestFlight build sends every answer
recording (raw 16 kHz WAV) plus its sidecar JSON while the diagnostics switch
"Save answer recordings" is on. Not a product feature: only bearer-verified
subjects on the ``VOICE_SAMPLE_UPLOAD_USER_IDS`` allowlist may upload; everyone
else gets 403 before anything is validated or stored.

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

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from pydantic import BaseModel
from sqlalchemy import select

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
router = APIRouter()

ALLOWLIST_ENV = "VOICE_SAMPLE_UPLOAD_USER_IDS"
# The app caps a capture at the dead-air cap (~15 s ≈ 0.5 MB at 16 kHz mono);
# 5 MB leaves room for a long answer and nothing more.
AUDIO_MAX_BYTES = 5 * 1024 * 1024
SIDECAR_MAX_BYTES = 64 * 1024
WAV_CONTENT_TYPES = {"audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave"}
STAMP_PATTERN = re.compile(r"^\d{8}-\d{6}-\d{3}$")
_READ_CHUNK_BYTES = 64 * 1024


def upload_allowlist() -> set[str]:
    """Subject ids allowed to upload, read live so a secret change applies on
    the next request (and tests can monkeypatch)."""
    raw = os.getenv(ALLOWLIST_ENV, "")
    return {part.strip() for part in raw.split(",") if part.strip()}


def require_sample_uploader(
    subject: AuthSubject = Depends(require_auth_or_grace),
) -> AuthSubject:
    """Only a verified bearer whose subject is allowlisted. The legacy grace
    pass-through (``authenticated=False``) never qualifies."""
    if not subject.authenticated or subject.subject_id not in upload_allowlist():
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
    async with sessionmaker() as session:
        existing = (
            await session.execute(
                select(VoiceSample.id).where(VoiceSample.r2_key == key)
            )
        ).scalar_one_or_none()
    if existing is not None:
        return VoiceSampleUploadResponse(id=str(existing), duplicate=True)

    try:
        await asyncio.to_thread(storage.put, key, audio_bytes, "audio/wav")
    except StorageNotConfigured as exc:
        logger.error("voice sample upload: %s", exc)
        raise HTTPException(
            status_code=503, detail="Voice sample storage not configured"
        )

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
    async with sessionmaker() as session:
        session.add(row)
        await session.commit()
    return VoiceSampleUploadResponse(id=str(row.id))


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
