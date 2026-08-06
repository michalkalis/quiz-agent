"""Quiz game flow endpoints: start, submit input, get question, rate."""

import logging
import sentry_sdk
from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.exc import OperationalError
from sqlalchemy.exc import TimeoutError as SATimeoutError

from ..deps import (
    StartQuizRequest,
    SubmitInputRequest,
    InputResponse,
    CurrentQuestionResponse,
    RateQuestionRequest,
    FlagQuestionRequest,
    get_session_manager,
    get_question_retriever,
    get_usage_tracker,
    get_feedback_service,
    get_quiz_flow,
    get_translation_service,
    get_tts_service,
    require_auth_or_grace,
    session_to_response,
    question_to_dict,
    question_to_dict_translated,
    flow_to_response,
)
from ..session_auth import require_session_ownership
from ...auth.identity import AuthSubject
from ...serializers import (
    apply_question_translation,
    session_translation,
    translated_question_payload,
)
from ...session.manager import SessionManager
from ...retrieval.question_retriever import QuestionRetriever
from ...rating.feedback import FeedbackService
from ...usage.tracker import UsageTracker
from ...tts.service import TTSService
from ...quiz.flow import QuestionMismatch, QuizFlowService, prefetch_question_audio
from ...tts.spoken_text import spoken_question_text
from ...rate_limit import limiter
from quiz_shared.models.phase import SessionPhase

logger = logging.getLogger(__name__)
router = APIRouter()

# #131 Track A: DB connection/pool errors typical of a Fly `auto_stop_machines`
# cold wake (staging) — surface these as a retryable 503 instead of a raw 500.
# ``OperationalError`` covers DBAPI/asyncpg disconnects; ``SATimeoutError`` is
# the SQLAlchemy pool-checkout timeout (pool exhaustion); ``ConnectionError``/
# ``TimeoutError`` catch a raw socket failure before SQLAlchemy wraps it.
_TRANSIENT_INFRA_ERRORS = (
    OperationalError,
    SATimeoutError,
    ConnectionError,
    TimeoutError,
)


@router.post("/sessions/{session_id}/start", response_model=InputResponse)
@limiter.limit("10/minute")
async def start_quiz(
    request: Request,
    session_id: str,
    body: StartQuizRequest,
    session_manager: SessionManager = Depends(get_session_manager),
    question_retriever: QuestionRetriever = Depends(get_question_retriever),
    usage_tracker: UsageTracker = Depends(get_usage_tracker),
    translation_service=Depends(get_translation_service),
    tts_service: TTSService = Depends(get_tts_service),
    audio: bool = False,
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """Start the quiz and get first question."""
    try:
        session = session_manager.get_session(session_id)
        # #144: the session id alone is not a credential — the bearer's subject
        # must own this session (404, never 403; see require_session_ownership).
        require_session_ownership(session, subject, session_id=session_id)

        if session.phase != SessionPhase.IDLE:
            raise HTTPException(status_code=400, detail="Quiz already started")

        # Check usage limit (freemium). #95: custom-pack sessions are paid,
        # curated content — they bypass the free monthly quota entirely.
        if usage_tracker and session.user_id and not session.pack_id:
            allowed, remaining, resets_at = await usage_tracker.check_limit(
                session.user_id
            )
            if not allowed:
                usage = await usage_tracker.get_usage(session.user_id)
                raise HTTPException(
                    status_code=429,
                    detail={
                        "error": "quota_limit_reached",
                        "questions_used": usage["questions_used"],
                        "questions_limit": usage["questions_limit"],
                        "resets_at": usage["resets_at"],
                        "upgrade_available": True,
                    },
                )

        client_excluded_ids = body.excluded_question_ids or []
        logger.debug("Client excluded %d questions", len(client_excluded_ids))
        # Persist on the session so every subsequent question (voice.py's
        # get_next_question has no client history of its own) keeps excluding
        # cross-session history, not just the first one.
        session.client_excluded_ids = client_excluded_ids

        # Phase transition is deferred to just before update_session() — if
        # question retrieval below fails, the stored session stays in IDLE
        # so the user can retry /start. (Mutating here would be lost since
        # get_session() returns a deep copy.)
        session.asked_question_ids = []

        # Get first question
        logger.debug(
            "Getting next question for session %s, difficulty: %s",
            session_id,
            session.current_difficulty,
        )
        try:
            # #151: awaited end to end (pgvector + embedding), so concurrent
            # /start calls overlap instead of serializing on one bridge thread.
            question = await question_retriever.get_next_question(
                session,
                client_excluded_ids=client_excluded_ids,
            )
        except Exception as e:
            logger.error("Exception in get_next_question: %s", e, exc_info=True)
            raise HTTPException(status_code=500, detail="Failed to retrieve question")

        if not question:
            logger.error("get_next_question returned None for session %s", session_id)
            total_count = await question_retriever.count(
                filters={"review_status": "approved"}
            )
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
                    filter_lines.append(
                        f"- Language-dependent: excluded (session language: {session.language})"
                    )
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

        if usage_tracker and session.user_id and not session.pack_id:
            await usage_tracker.record_question(session.user_id)

        (
            translated_question_dict,
            translation_record,
        ) = await translated_question_payload(
            question, session.language, translation_service, session_id=session_id
        )
        session.current_question_text = translated_question_dict["question"]
        session.current_question_translation = translation_record
        session.transition(to=SessionPhase.ASKING, caller="routes.start_quiz")
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
            prefetch_question_audio(
                tts_service,
                spoken_question_text(
                    translated_question_dict["question"],
                    translated_question_dict.get("possible_answers"),
                ),
                session.language,
            )

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
        raise HTTPException(status_code=500, detail="Failed to start quiz")


@router.post("/sessions/{session_id}/input", response_model=InputResponse)
@limiter.limit("30/minute")
async def submit_input(
    request: Request,
    session_id: str,
    body: SubmitInputRequest,
    session_manager: SessionManager = Depends(get_session_manager),
    quiz_flow: QuizFlowService = Depends(get_quiz_flow),
    audio: bool = False,
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """Submit user input (AI-powered natural language parsing)."""
    # The whole read→process→write is serialized per session: the flow mutates a
    # deep copy across several awaits and writes it back wholesale, so overlapping
    # submits would lose one another's advance (see SessionManager.session_lock).
    async with session_manager.session_lock(session_id):
        session = session_manager.get_session(session_id)
        require_session_ownership(session, subject, session_id=session_id)  # #144

        if session.phase not in (SessionPhase.ASKING, SessionPhase.AWAITING_ANSWER):
            raise HTTPException(status_code=400, detail="Not waiting for input")

        try:
            flow_result = await quiz_flow.process_answer(
                session=session,
                answer_text=body.input,
                participant_id=body.participant_id,
                include_audio=audio,
                submitted_question_id=body.question_id,
            )
        except QuestionMismatch as e:
            # #133 1a: the client is a whole question out of step. Grading this
            # text would score a question the player never saw, so refuse and hand
            # back the id to resync on. Nothing was mutated.
            raise HTTPException(
                status_code=409,
                detail={
                    "code": "question_mismatch",
                    "current_question_id": e.current_question_id,
                },
            )
        except _TRANSIENT_INFRA_ERRORS as e:
            # Cold-wake DB hiccup (staging auto_stop_machines) or pool exhaustion —
            # retryable, not a bug. iOS retries on 502/503 (isTransientStartError).
            logger.warning(
                "Transient infra error in submit_input (session=%s): %s", session_id, e
            )
            raise HTTPException(
                status_code=503, detail="Temporary server issue, please retry"
            )
        except Exception as e:
            logger.error("Unexpected exception in submit_input: %s", e, exc_info=True)
            if sentry_sdk.get_client().is_active():
                sentry_sdk.capture_exception(e)
            raise HTTPException(status_code=500, detail="Failed to process your answer")

        # Ghost-question guard (#66): a non-answer intent leaves the session
        # untouched (no current_question_id advance, no question recorded). Surface
        # it as a 400 instead of silently returning an empty response.
        if flow_result.evaluation is None:
            raise HTTPException(
                status_code=400,
                detail="Could not understand your answer. Please try again.",
            )

        if flow_result.usage_limit_error:
            raise HTTPException(status_code=429, detail=flow_result.usage_limit_error)

        return flow_to_response(flow_result, session)


@router.get("/sessions/{session_id}/question", response_model=CurrentQuestionResponse)
async def get_current_question(
    session_id: str,
    session_manager: SessionManager = Depends(get_session_manager),
    question_retriever: QuestionRetriever = Depends(get_question_retriever),
    translation_service=Depends(get_translation_service),
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """Get current question without submitting input."""
    session = session_manager.get_session(session_id)
    require_session_ownership(session, subject, session_id=session_id)  # #144

    if not session.current_question_id:
        raise HTTPException(status_code=400, detail="No active question")

    question = await question_retriever.get(session.current_question_id)
    if not question:
        raise HTTPException(status_code=500, detail="Question not found")

    record = session_translation(session, question.id)
    if record:
        # Serve the exact payload the player was already shown — never re-translate.
        translated_question = apply_question_translation(
            question_to_dict(question), record
        )
    elif session.current_question_text:
        # Pre-#132 session (or a fallback-to-English serve): stem only.
        question_dict = question_to_dict(question)
        question_dict["question"] = session.current_question_text
        translated_question = question_dict
    else:
        translated_question = await question_to_dict_translated(
            question, session.language, translation_service, session_id=session_id
        )

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
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """Rate the current or last question."""
    session = session_manager.get_session(session_id)
    require_session_ownership(session, subject, session_id=session_id)  # #144

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
        session_id=session_id,
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
    subject: AuthSubject = Depends(require_auth_or_grace),
):
    """Flag the current question as potentially incorrect."""
    session = session_manager.get_session(session_id)
    require_session_ownership(session, subject, session_id=session_id)  # #144

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
