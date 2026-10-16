"""Dictation transcription: a short clip in, its text out (#208.8).

The feedback form, the question rating and the custom-pack prompt let the
player dictate instead of type. Until #208 that streamed to ElevenLabs
realtime STT; the founder moved all speech-to-text to OpenAI gpt-transcribe
(2026-10-16), so the app now records the clip and sends it here once the
player stops. No session and no quiz context: the text is free-form.

Same guards as ``/voice/submit``: the recogniser's format and size checks and
the per-account daily STT seconds cap, both before anything is paid for.
"""

import logging
from typing import Optional

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    HTTPException,
    Request,
    UploadFile,
)
from pydantic import BaseModel, Field

from ..deps import get_usage_caps, get_voice_transcriber, require_auth_or_grace
from ...auth.identity import AuthSubject
from ...config import get_settings
from ...quiz.errors import InvalidSubmission
from ...rate_limit import limiter
from ...usage.caps import STT_SECONDS, DailyCapExceeded, UsageCaps, recording_seconds
from ...voice.transcriber import VoiceTranscriber

logger = logging.getLogger(__name__)
router = APIRouter()


class DictationResponse(BaseModel):
    text: str = Field(
        description=(
            "What the player said, trimmed. Empty when nothing intelligible was "
            "heard (silence, noise, a known recogniser hallucination)."
        )
    )


@router.post("/voice/dictation", response_model=DictationResponse)
@limiter.limit("10/minute")
async def transcribe_dictation(
    request: Request,
    audio: UploadFile = File(..., description="The dictated clip (16-bit WAV)"),
    language: Optional[str] = Form(
        default=None,
        pattern=r"^[a-z]{2}$",
        description="ISO 639-1 language hint (sk, cs, en). Missing = auto-detect.",
    ),
    subject: AuthSubject = Depends(require_auth_or_grace),
    voice_transcriber: VoiceTranscriber = Depends(get_voice_transcriber),
    usage_caps: UsageCaps = Depends(get_usage_caps),
) -> DictationResponse:
    # Only new builds call this and they always carry a bearer; without a
    # verified subject the daily cap below could not count anything.
    if not subject.authenticated or not subject.subject_id:
        raise HTTPException(status_code=401, detail="Authentication required")
    if not voice_transcriber.is_supported_format(audio.filename or ""):
        raise HTTPException(
            status_code=400,
            detail="Unsupported audio format. Supported: "
            f"{', '.join(sorted(VoiceTranscriber.SUPPORTED_FORMATS))}",
        )
    try:
        await usage_caps.consume(
            subject.subject_id,
            STT_SECONDS,
            recording_seconds(audio.file),
            get_settings().daily_cap_stt_seconds,
        )
    except DailyCapExceeded as exc:
        raise exc.http_error() from exc

    try:
        result = await voice_transcriber.transcribe(
            audio_file=audio.file, filename=audio.filename, language=language
        )
    except InvalidSubmission as exc:  # size: message built from facts, safe
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        logger.warning("Dictation transcription failed: %s", type(exc).__name__)
        raise HTTPException(status_code=502, detail="Transcription failed") from exc

    # A hallucination on silence ("Thank you.") must not land in the form.
    text = result.text.strip() if result.is_valid(min_chars=1) else ""
    logger.info("Dictation transcribed chars=%d", len(text))  # #193: no words
    return DictationResponse(text=text)
