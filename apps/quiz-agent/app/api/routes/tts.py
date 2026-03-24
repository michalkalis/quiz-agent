"""Text-to-Speech and audio feedback endpoints."""

import logging
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response

from ..deps import (
    SynthesizeTTSRequest,
    get_session_manager, get_tts_service, get_chroma_client, get_translation_service,
    question_to_dict_translated,
)
from ...session.manager import SessionManager
from ...tts.service import TTSService
from ...rate_limit import limiter

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/tts/synthesize")
@limiter.limit("60/minute")
async def synthesize_tts(
    http_request: Request,
    request: SynthesizeTTSRequest,
    tts_service: TTSService = Depends(get_tts_service),
):
    """Generate speech audio from text (generic TTS)."""
    try:
        audio_data = await tts_service.synthesize(
            text=request.text, voice=request.voice, use_cache=True
        )
        return Response(
            content=audio_data,
            media_type=f"audio/{request.format}",
            headers={"Content-Disposition": f'attachment; filename="speech.{request.format}"'},
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"TTS synthesis failed: {str(e)}")


@router.get("/sessions/{session_id}/question/audio")
@limiter.limit("60/minute")
async def get_question_audio(
    request: Request,
    session_id: str,
    session_manager: SessionManager = Depends(get_session_manager),
    tts_service: TTSService = Depends(get_tts_service),
    chroma_client=Depends(get_chroma_client),
    translation_service=Depends(get_translation_service),
):
    """Get audio for current question in session (cached)."""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    if not session.current_question_id:
        raise HTTPException(status_code=400, detail="No active question in session")

    try:
        if session.current_question_text:
            question_text = session.current_question_text
        else:
            current_question = chroma_client.get_question(session.current_question_id)
            if not current_question:
                raise HTTPException(status_code=404, detail="Current question not found")

            translated_dict = await question_to_dict_translated(current_question, session.language, translation_service)
            question_text = translated_dict["question"]

            session.current_question_text = question_text
            session_manager.update_session(session)

        audio_data = await tts_service.synthesize_question(question_text=question_text)

        return Response(
            content=audio_data,
            media_type="audio/opus",
            headers={
                "Content-Disposition": 'attachment; filename="question.opus"',
                "Cache-Control": "public, max-age=3600",
            },
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Audio generation failed: {str(e)}")


@router.get("/tts/feedback/{result}")
async def get_feedback_audio(
    result: str,
    tts_service: TTSService = Depends(get_tts_service),
    variant: Optional[int] = None,
):
    """Get pre-cached feedback audio (instant response)."""
    valid_results = ["correct", "incorrect", "partially_correct", "partially_incorrect", "skipped"]
    if result not in valid_results:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid result. Must be one of: {', '.join(valid_results)}",
        )

    try:
        audio_data = await tts_service.get_feedback_audio(result, variant)
        if not audio_data:
            raise HTTPException(
                status_code=404,
                detail=f"Feedback audio not found for result '{result}'.",
            )

        return Response(
            content=audio_data,
            media_type="audio/opus",
            headers={
                "Content-Disposition": f'attachment; filename="feedback_{result}.opus"',
                "Cache-Control": "public, max-age=86400",
            },
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to retrieve feedback audio: {str(e)}")


@router.get("/sessions/{session_id}/feedback/{result}/audio")
async def get_session_feedback_audio(
    session_id: str,
    result: str,
    session_manager: SessionManager = Depends(get_session_manager),
    tts_service: TTSService = Depends(get_tts_service),
    translation_service=Depends(get_translation_service),
):
    """Get feedback audio in session's language."""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    valid_results = ["correct", "incorrect", "partially_correct", "partially_incorrect", "skipped"]
    if result not in valid_results:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid result. Must be one of: {', '.join(valid_results)}",
        )

    try:
        from ...translation import get_feedback_message

        feedback_text = get_feedback_message(result, session.language)
        audio_data = await tts_service.synthesize(feedback_text, use_cache=True)

        return Response(
            content=audio_data,
            media_type="audio/opus",
            headers={
                "Content-Disposition": f'attachment; filename="feedback_{result}_{session.language}.opus"',
                "Cache-Control": "public, max-age=3600",
            },
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to generate feedback audio: {str(e)}")
