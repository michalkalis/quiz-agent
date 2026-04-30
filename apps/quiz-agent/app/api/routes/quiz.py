"""Quiz game flow endpoints: start, submit input, get question, rate."""

import logging
from fastapi import APIRouter, Depends, HTTPException, Request

from ..deps import (
    StartQuizRequest, SubmitInputRequest, InputResponse, RateQuestionRequest,
    FlagQuestionRequest,
    get_session_manager, get_question_retriever, get_question_store,
    get_usage_tracker, get_feedback_service, get_quiz_flow, get_translation_service,
    get_tts_service,
    session_to_response, question_to_dict, question_to_dict_translated, flow_to_response,
)
from ...session.manager import SessionManager
from ...retrieval.question_retriever import QuestionRetriever
from ...rating.feedback import FeedbackService
from ...usage.tracker import UsageTracker
from ...tts.service import TTSService
from ...quiz.flow import QuizFlowService, prefetch_question_audio
from ...rate_limit import limiter

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/sessions/{session_id}/start", response_model=InputResponse)
@limiter.limit("10/minute")
async def start_quiz(
    request: Request,
    session_id: str,
    body: StartQuizRequest,
    session_manager: SessionManager = Depends(get_session_manager),
    question_retriever: QuestionRetriever = Depends(get_question_retriever),
    store=Depends(get_question_store),
    usage_tracker: UsageTracker = Depends(get_usage_tracker),
    translation_service=Depends(get_translation_service),
    tts_service: TTSService = Depends(get_tts_service),
    audio: bool = False,
):
    """Start the quiz and get first question."""
    try:
        session = session_manager.get_session(session_id)
        if not session:
            raise HTTPException(status_code=404, detail="Session not found or expired")

        if session.phase != "idle":
            raise HTTPException(status_code=400, detail="Quiz already started")

        # Check usage limit (freemium)
        if usage_tracker and session.user_id:
            allowed, remaining, resets_at = usage_tracker.check_limit(session.user_id)
            if not allowed:
                usage = usage_tracker.get_usage(session.user_id)
                raise HTTPException(
                    status_code=429,
                    detail={
                        "error": "daily_limit_reached",
                        "questions_used": usage["questions_used"],
                        "questions_limit": usage["questions_limit"],
                        "resets_at": usage["resets_at"],
                        "upgrade_available": True,
                    },
                )

        client_excluded_ids = body.excluded_question_ids or []
        logger.debug("Client excluded %d questions", len(client_excluded_ids))

        session.phase = "asking"
        session.asked_question_ids = []

        # Get first question
        logger.debug("Getting next question for session %s, difficulty: %s", session_id, session.current_difficulty)
        try:
            question = question_retriever.get_next_question(
                session, client_excluded_ids=client_excluded_ids
            )
        except Exception as e:
            logger.error("Exception in get_next_question: %s", e, exc_info=True)
            raise HTTPException(status_code=500, detail=f"Failed to retrieve question: {str(e)}")

        if not question:
            logger.error("get_next_question returned None for session %s", session_id)
            total_count = store.count(filters={"review_status": "approved"}) if store else 0
            client_seen_count = len(client_excluded_ids)

            if total_count > 0 and client_seen_count >= total_count * 0.8:
                raise HTTPException(
                    status_code=409,
                    detail={
                        "message": "You've seen most available questions",
                        "total_questions": total_count,
                        "questions_seen": client_seen_count,
                        "suggestion": "reset_history",
                    },
                )

            if total_count == 0:
                error_detail = (
                    "The question database is empty. "
                    "Please generate or import questions first."
                )
            else:
                filter_lines = [
                    f"- Difficulty: {session.current_difficulty}",
                    "- Type: text",
                    "- Review status: approved",
                ]
                if session.language and session.language != "en":
                    filter_lines.append(f"- Language-dependent: excluded (session language: {session.language})")
                if session.preferred_categories:
                    filter_lines.append(f"- Categories: {session.preferred_categories}")
                error_detail = (
                    f"No questions match the criteria. "
                    f"Database has {total_count} approved questions, but none match:\n"
                    + "\n".join(filter_lines)
                )
            raise HTTPException(status_code=500, detail=error_detail)

        session.current_question_id = question.id
        session.asked_question_ids.append(question.id)

        if usage_tracker and session.user_id:
            usage_tracker.record_question(session.user_id)

        translated_question_dict = await question_to_dict_translated(question, session.language, translation_service)
        session.current_question_text = translated_question_dict["question"]
        session_manager.update_session(session)

        audio_info = None
        if audio:
            audio_info = {
                "question_url": f"/api/v1/sessions/{session_id}/question/audio",
                "format": "opus",
            }
            # Warm TTS cache while iOS is still rendering the question UI.
            # Best-effort: if iOS requests audio before this finishes, both calls
            # run in parallel and the second wins (cache write is idempotent).
            prefetch_question_audio(tts_service, translated_question_dict["question"])

        return InputResponse(
            success=True,
            message="Quiz started",
            session=session_to_response(session),
            current_question=translated_question_dict,
            feedback_received=[],
            audio=audio_info,
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error("Unexpected exception in start_quiz: %s", e, exc_info=True)
        raise HTTPException(status_code=500, detail=f"Failed to start quiz: {str(e)}")


@router.post("/sessions/{session_id}/input", response_model=InputResponse)
@limiter.limit("30/minute")
async def submit_input(
    request: Request,
    session_id: str,
    body: SubmitInputRequest,
    session_manager: SessionManager = Depends(get_session_manager),
    quiz_flow: QuizFlowService = Depends(get_quiz_flow),
    audio: bool = False,
):
    """Submit user input (AI-powered natural language parsing)."""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    if session.phase not in ["asking", "awaiting_answer"]:
        raise HTTPException(status_code=400, detail="Not waiting for input")

    flow_result = await quiz_flow.process_answer(
        session=session,
        answer_text=body.input,
        participant_id=body.participant_id,
        include_audio=audio,
    )

    if flow_result.usage_limit_error:
        raise HTTPException(status_code=429, detail=flow_result.usage_limit_error)

    return flow_to_response(flow_result, session)


@router.get("/sessions/{session_id}/question")
async def get_current_question(
    session_id: str,
    session_manager: SessionManager = Depends(get_session_manager),
    store=Depends(get_question_store),
    translation_service=Depends(get_translation_service),
):
    """Get current question without submitting input."""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    if not session.current_question_id:
        raise HTTPException(status_code=400, detail="No active question")

    if session.current_question_text:
        question = store.get(session.current_question_id)
        if not question:
            raise HTTPException(status_code=500, detail="Question not found")
        question_dict = question_to_dict(question)
        question_dict["question"] = session.current_question_text
        translated_question = question_dict
    else:
        question = store.get(session.current_question_id)
        if not question:
            raise HTTPException(status_code=500, detail="Question not found")
        translated_question = await question_to_dict_translated(question, session.language, translation_service)

    return {
        "question": translated_question,
        "progress": {
            "current": len(session.asked_question_ids),
            "total": session.max_questions,
        },
    }


@router.post("/sessions/{session_id}/rate")
async def rate_question(
    session_id: str,
    request: RateQuestionRequest,
    session_manager: SessionManager = Depends(get_session_manager),
    feedback_service: FeedbackService = Depends(get_feedback_service),
):
    """Rate the current or last question."""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    if not session.current_question_id:
        raise HTTPException(status_code=400, detail="No question to rate")

    user_id = session.user_id
    if request.participant_id:
        for p in session.participants:
            if p.participant_id == request.participant_id:
                user_id = p.user_id or p.participant_id
                break

    user_id = user_id or "anonymous"

    success, message = await feedback_service.submit_rating(
        question_id=session.current_question_id,
        user_id=user_id,
        rating=request.rating,
        feedback_text=request.feedback_text,
    )

    if not success:
        raise HTTPException(status_code=500, detail=message)

    return {"success": True, "message": message}


@router.post("/sessions/{session_id}/flag")
@limiter.limit("10/minute")
async def flag_question(
    request: Request,
    session_id: str,
    body: FlagQuestionRequest,
    session_manager: SessionManager = Depends(get_session_manager),
    feedback_service: FeedbackService = Depends(get_feedback_service),
):
    """Flag the current question as potentially incorrect."""
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    if not session.current_question_id:
        raise HTTPException(status_code=400, detail="No question to flag")

    user_id = session.user_id
    if body.participant_id:
        for p in session.participants:
            if p.participant_id == body.participant_id:
                user_id = p.user_id or p.participant_id
                break

    user_id = user_id or "anonymous"

    success, message = await feedback_service.flag_question(
        question_id=session.current_question_id,
        user_id=user_id,
        reason=body.reason,
    )

    if not success:
        raise HTTPException(status_code=500, detail=message)

    return {"success": True, "message": message}
