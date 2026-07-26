"""Text-to-Speech and audio feedback endpoints."""

import logging
from typing import Optional

import sentry_sdk
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response
from quiz_shared.models.question import Question

from ..deps import (
    SynthesizeTTSRequest,
    get_session_manager,
    get_tts_service,
    get_question_retriever,
    get_translation_service,
    question_to_dict_translated,
    require_auth_or_grace,
)
from ...session.manager import SessionManager
from ...retrieval.question_retriever import QuestionRetriever
from ...tts.question_speech import build_question_speech_text
from ...tts.service import TTSService
from ...rate_limit import limiter

logger = logging.getLogger(__name__)
router = APIRouter()


def _question_row_for_speech(
    question_retriever: QuestionRetriever, question_id: str
) -> Optional[Question]:
    """The question row needed to speak its options, or None — never raises.

    Reached only when a session has no cached speech text. Losing the row costs
    the driver the option read-out, which is bad but survivable; failing the
    request costs the whole question, which is not. So the lookup degrades and
    reports to Sentry instead — same fail-loud-but-keep-driving shape as
    ``boost_volume`` (4e72ce6).
    """
    reason = "no such question row"
    try:
        question = question_retriever.get(question_id)
        if question is not None:
            return question
    except Exception as e:
        reason = f"question store lookup failed: {e}"

    message = (
        f"Speaking question {question_id} without its multiple-choice options "
        f"({reason}) — a driver who cannot see the picker cannot answer it"
    )
    logger.error(message)
    sentry_sdk.capture_message(message, level="error")
    return None


@router.post("/tts/synthesize")
@limiter.limit("60/minute")
async def synthesize_tts(
    request: Request,
    body: SynthesizeTTSRequest,
    tts_service: TTSService = Depends(get_tts_service),
    _auth=Depends(require_auth_or_grace),
):
    """Generate speech audio from text (generic TTS)."""
    try:
        audio_data = await tts_service.synthesize(
            text=body.text, voice=body.voice, use_cache=True
        )
        return Response(
            content=audio_data,
            media_type=f"audio/{body.format}",
            headers={
                "Content-Disposition": f'attachment; filename="speech.{body.format}"'
            },
        )
    except ValueError as e:
        # Constructed validation text ("Text cannot be empty") — client-safe.
        logger.warning("TTS synthesis rejected: %s", e)
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        logger.error("TTS synthesis failed: %s", e, exc_info=True)
        raise HTTPException(status_code=500, detail="TTS synthesis failed")


@router.get("/sessions/{session_id}/question/audio")
@limiter.limit("60/minute")
async def get_question_audio(
    request: Request,
    session_id: str,
    session_manager: SessionManager = Depends(get_session_manager),
    tts_service: TTSService = Depends(get_tts_service),
    question_retriever: QuestionRetriever = Depends(get_question_retriever),
    translation_service=Depends(get_translation_service),
    _auth=Depends(require_auth_or_grace),
):
    """Get audio for current question in session (cached)."""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    if not session.current_question_id:
        raise HTTPException(status_code=400, detail="No active question in session")

    try:
        # Hot path: the spoken text — MCQ options appended, digits spelled out
        # (founder bug 2026-07-12) — was assembled where the question was chosen
        # and cached on the session, which is also the exact string the TTS
        # warm-up hashed. No question-store round trip: QuestionRetriever.get
        # blocks this event-loop thread on Postgres, and a DB blip must never
        # cost a driver audio that is already synthesized and cached.
        tts_text = session.current_question_speech_text

        if not tts_text:
            # Only sessions written before the speech text was cached (a rolling
            # deploy mid-quiz, or a restored session) land here.
            current_question = _question_row_for_speech(
                question_retriever, session.current_question_id
            )
            question_text = session.current_question_text
            options = None

            if current_question is not None:
                # Re-project rather than read the row's own English options: the
                # driver must hear the choices in the session language here too.
                # Both translations are keyed by the source English text, so this
                # is a cache hit for a question that was already asked — the
                # durable store carries it across the very restart that empties
                # the session's cached speech text.
                translated_dict = await question_to_dict_translated(
                    current_question,
                    session.language,
                    translation_service,
                    session_id=session_id,
                )
                options = translated_dict["possible_answers"]
                # The session's copy stays authoritative: it is what the client
                # was already shown, so speech can't drift from the screen.
                question_text = question_text or translated_dict["question"]
                session.current_question_text = question_text
            elif not question_text:
                raise HTTPException(
                    status_code=404, detail="Current question not found"
                )

            tts_text = build_question_speech_text(
                question_text, current_question, session.language, options=options
            )
            # Never cache a build made without the row: it carries no options,
            # and every later request for this question would inherit it.
            if current_question is not None:
                session.current_question_speech_text = tts_text
            session_manager.update_session(session)

        audio_data = await tts_service.synthesize_question(question_text=tts_text)

        return Response(
            content=audio_data,
            media_type="audio/opus",
            headers={
                "Content-Disposition": 'attachment; filename="question.opus"',
                "Cache-Control": "public, max-age=3600",
            },
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error(
            "Audio generation failed for session %s: %s", session_id, e, exc_info=True
        )
        raise HTTPException(status_code=500, detail="Audio generation failed")


@router.get("/tts/feedback/{result}")
async def get_feedback_audio(
    result: str,
    tts_service: TTSService = Depends(get_tts_service),
    variant: Optional[int] = None,
):
    """Get pre-cached feedback audio (instant response)."""
    valid_results = [
        "correct",
        "incorrect",
        "partially_correct",
        "partially_incorrect",
        "skipped",
    ]
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
        logger.error(
            "Failed to retrieve feedback audio for '%s': %s", result, e, exc_info=True
        )
        raise HTTPException(status_code=500, detail="Failed to retrieve feedback audio")


@router.get("/sessions/{session_id}/feedback/{result}/audio")
async def get_session_feedback_audio(
    session_id: str,
    result: str,
    session_manager: SessionManager = Depends(get_session_manager),
    tts_service: TTSService = Depends(get_tts_service),
    translation_service=Depends(get_translation_service),
    _auth=Depends(require_auth_or_grace),
):
    """Get feedback audio in session's language."""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    valid_results = [
        "correct",
        "incorrect",
        "partially_correct",
        "partially_incorrect",
        "skipped",
    ]
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
        logger.error(
            "Failed to generate feedback audio for session %s: %s",
            session_id,
            e,
            exc_info=True,
        )
        raise HTTPException(status_code=500, detail="Failed to generate feedback audio")
