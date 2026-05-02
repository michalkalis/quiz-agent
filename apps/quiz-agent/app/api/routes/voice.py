"""Voice transcription and submission endpoints."""

import asyncio
import logging
from difflib import SequenceMatcher
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Request, UploadFile, File

from ..deps import (
    InputResponse,
    get_session_manager, get_voice_transcriber, get_question_retriever,
    get_quiz_flow,
    flow_to_response,
)
from ...session.manager import SessionManager
from ...voice.transcriber import VoiceTranscriber
from ...retrieval.question_retriever import QuestionRetriever
from ...quiz.flow import QuizFlowService
from ...rate_limit import limiter
from quiz_shared.models.phase import SessionPhase

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/voice/transcribe")
@limiter.limit("30/minute")
async def transcribe_audio(
    request: Request,
    voice_transcriber: VoiceTranscriber = Depends(get_voice_transcriber),
    audio: UploadFile = File(..., description="Audio file (mp3, wav, m4a, etc.)"),
):
    """Transcribe audio file to text."""
    try:
        if not voice_transcriber.is_supported_format(audio.filename):
            raise HTTPException(
                status_code=400,
                detail=f"Unsupported audio format. Supported: {', '.join(VoiceTranscriber.SUPPORTED_FORMATS)}",
            )

        result = await voice_transcriber.transcribe(audio_file=audio.file, filename=audio.filename)

        return {
            "success": True,
            "text": result.text,
            "language": result.language,
            "filename": audio.filename,
            "confidence": {
                "no_speech_prob": result.no_speech_prob,
                "avg_logprob": result.avg_logprob,
                "is_valid": result.is_valid(),
            },
        }
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=500, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Transcription failed: {str(e)}")


@router.post("/voice/submit/{session_id}", response_model=InputResponse)
@limiter.limit("30/minute")
async def transcribe_and_submit(
    request: Request,
    session_id: str,
    session_manager: SessionManager = Depends(get_session_manager),
    voice_transcriber: VoiceTranscriber = Depends(get_voice_transcriber),
    question_retriever: QuestionRetriever = Depends(get_question_retriever),
    quiz_flow: QuizFlowService = Depends(get_quiz_flow),
    audio: UploadFile = File(..., description="Audio file with quiz answer"),
    participant_id: Optional[str] = None,
    include_audio: bool = True,
):
    """Transcribe audio and submit to quiz (one-step voice operation)."""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    if session.phase not in (SessionPhase.ASKING, SessionPhase.AWAITING_ANSWER):
        raise HTTPException(status_code=400, detail="Not waiting for input")

    try:
        if not voice_transcriber.is_supported_format(audio.filename):
            raise HTTPException(
                status_code=400,
                detail=f"Unsupported audio format. Supported: {', '.join(VoiceTranscriber.SUPPORTED_FORMATS)}",
            )

        current_question = question_retriever.get(session.current_question_id)
        if not current_question:
            raise HTTPException(status_code=500, detail="Current question not found")

        # Transcribe with quiz context
        transcription_result = await voice_transcriber.transcribe_with_quiz_context(
            audio_file=audio.file,
            filename=audio.filename,
            current_question=current_question.question,
            language=session.language,
        )

        if not transcription_result.is_valid():
            rejection_reason = transcription_result.get_rejection_reason()
            logger.warning(
                "Transcription rejected for session %s: %s (text='%s', no_speech=%.3f, logprob=%.3f)",
                session_id, rejection_reason, transcription_result.text,
                transcription_result.no_speech_prob, transcription_result.avg_logprob,
            )
            raise HTTPException(
                status_code=400,
                detail="No clear speech detected. Please speak clearly and try again.",
            )

        transcribed_text = transcription_result.text
        logger.info(
            "Transcribed: '%s' (no_speech=%.2f, logprob=%.2f)",
            transcribed_text, transcription_result.no_speech_prob, transcription_result.avg_logprob,
        )

        # Contamination detection
        if len(transcribed_text) > 100:
            logger.warning("Transcription unusually long (%d chars) - possible TTS leakage", len(transcribed_text))
        similarity = SequenceMatcher(None, transcribed_text.lower(), current_question.question.lower()).ratio()
        if similarity > 0.5:
            logger.warning("Transcription %.0f%% similar to question - possible TTS leakage", similarity * 100)

        # Parallel next-question prefetch
        next_question_task = None
        if len(session.asked_question_ids) < session.max_questions:
            next_question_task = asyncio.create_task(
                asyncio.to_thread(question_retriever.get_next_question, session)
            )

        next_question = None
        if next_question_task:
            next_question = await next_question_task

        # Delegate to shared quiz flow
        flow_result = await quiz_flow.process_answer(
            session=session,
            answer_text=transcribed_text,
            participant_id=participant_id,
            include_audio=include_audio,
            next_question=next_question,
        )

        # Voice-specific: require an answer intent
        if flow_result.evaluation is None:
            logger.warning("No answer intent detected in transcription: '%s'", transcribed_text)
            raise HTTPException(
                status_code=400,
                detail="Could not understand your answer. Please speak clearly and try again.",
            )

        flow_result.feedback_received.insert(0, f"voice_input: {transcribed_text}")
        flow_result.message = "Voice input processed"

        if flow_result.usage_limit_error:
            raise HTTPException(status_code=429, detail=flow_result.usage_limit_error)

        return flow_to_response(flow_result, session)

    except HTTPException:
        raise
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=500, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Voice submission failed: {str(e)}")
