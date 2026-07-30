"""Voice transcription and submission endpoints."""

import asyncio
import logging
from difflib import SequenceMatcher
from typing import Optional
from fastapi import (
    APIRouter,
    Depends,
    File,
    HTTPException,
    Query,
    Request,
    UploadFile,
)

from ..deps import (
    InputResponse,
    get_session_manager,
    get_voice_transcriber,
    get_question_retriever,
    get_quiz_flow,
    flow_to_response,
    require_auth_or_grace,
)
from ...session.manager import SessionManager
from ...voice.transcriber import VoiceTranscriber
from ...retrieval.question_retriever import QuestionRetriever
from ...quiz.flow import QuestionMismatch, QuizFlowService
from ...rate_limit import limiter
from quiz_shared.models.phase import SessionPhase

logger = logging.getLogger(__name__)
router = APIRouter()


# NOTE: a bare ``POST /voice/transcribe`` (transcribe-only, no session) used to
# live here. It was removed 2026-07-30 (#133 audit V6a): no client ever called it,
# yet it billed a Whisper transcription per request at 30/min on the same
# bearer-or-grace auth as the rest of the voice surface — spend with no product
# behind it. Transcription happens only as part of /voice/submit, where it is
# metered by the session it feeds.
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
    question_id: Optional[str] = Query(
        default=None,
        description=(
            "The question this recording answers (#133). Send it on every submit: "
            "a retry of an already-graded submission is then replayed (or "
            "re-graded against that same question if the new transcript differs) "
            "instead of being scored against the next question and charging a "
            "second freemium question. An id the session cannot grade gets 409 "
            "`question_mismatch` before any transcription is paid for. Omit for "
            "the legacy behaviour."
        ),
    ),
    include_audio: bool = True,
    _auth=Depends(require_auth_or_grace),
):
    """Transcribe audio and submit to quiz (one-step voice operation)."""
    # The whole read→process→write is serialized per session: the flow mutates a
    # deep copy across several awaits and writes it back wholesale, so overlapping
    # submits would lose one another's advance (see SessionManager.session_lock).
    async with session_manager.session_lock(session_id):
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

            # #133 1a: reject an out-of-step question_id here, before paying
            # OpenAI for a transcription the flow would refuse to grade anyway.
            is_resubmission = quiz_flow.classify_submission(session, question_id)

            # Transcribe against the question this recording is FOR: a retry of a
            # lost submit carries the already-graded id, and priming Whisper with
            # the question the session has since advanced to would transcribe the
            # same audio differently — turning a free replay into a paid re-grade.
            current_question = await asyncio.to_thread(
                question_retriever.get, question_id or session.current_question_id
            )
            if not current_question:
                raise HTTPException(
                    status_code=500, detail="Current question not found"
                )

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
                    session_id,
                    rejection_reason,
                    transcription_result.text,
                    transcription_result.no_speech_prob,
                    transcription_result.avg_logprob,
                )
                raise HTTPException(
                    status_code=400,
                    detail="No clear speech detected. Please speak clearly and try again.",
                )

            transcribed_text = transcription_result.text
            logger.info(
                "Transcribed: '%s' (no_speech=%.2f, logprob=%.2f)",
                transcribed_text,
                transcription_result.no_speech_prob,
                transcription_result.avg_logprob,
            )

            # Contamination detection
            if len(transcribed_text) > 100:
                logger.warning(
                    "Transcription unusually long (%d chars) - possible TTS leakage",
                    len(transcribed_text),
                )
            similarity = SequenceMatcher(
                None, transcribed_text.lower(), current_question.question.lower()
            ).ratio()
            if similarity > 0.5:
                logger.warning(
                    "Transcription %.0f%% similar to question - possible TTS leakage",
                    similarity * 100,
                )

            # Parallel next-question prefetch. Skipped for a re-submitted question
            # (#133 1a): that path never advances, so the retrieval — a pgvector
            # query plus an embedding call — would be paid for nothing.
            next_question_task = None
            if (
                not is_resubmission
                and len(session.asked_question_ids) < session.max_questions
            ):
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
                submitted_question_id=question_id,
            )

            # Voice-specific: require an answer intent
            if flow_result.evaluation is None:
                logger.warning(
                    "No answer intent detected in transcription: '%s'", transcribed_text
                )
                raise HTTPException(
                    status_code=400,
                    detail="Could not understand your answer. Please speak clearly and try again.",
                )

            flow_result.feedback_received.insert(0, f"voice_input: {transcribed_text}")
            flow_result.message = "Voice input processed"

            if flow_result.usage_limit_error:
                raise HTTPException(
                    status_code=429, detail=flow_result.usage_limit_error
                )

            return flow_to_response(flow_result, session)

        except HTTPException:
            raise
        except QuestionMismatch as e:
            # #133 1a: the client is a whole question out of step. Grading this
            # recording would score a question the player never saw, so refuse and
            # hand back the id to resync on. Nothing was mutated.
            raise HTTPException(
                status_code=409,
                detail={
                    "code": "question_mismatch",
                    "current_question_id": e.current_question_id,
                },
            )
        except ValueError as e:
            # Constructed validation text (format/size) — client-safe by design.
            logger.warning(
                "Voice submission rejected for session %s: %s", session_id, e
            )
            raise HTTPException(status_code=400, detail=str(e))
        except Exception as e:
            logger.error(
                "Voice submission failed for session %s: %s",
                session_id,
                e,
                exc_info=True,
            )
            raise HTTPException(status_code=500, detail="Voice submission failed")
