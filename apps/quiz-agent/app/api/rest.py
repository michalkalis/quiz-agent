"""Client-agnostic REST API for Quiz Agent.

Designed to work with any client: iOS app, terminal, TV app, web.
All responses are structured JSON with consistent format.
"""

from typing import Optional, List, Dict, Any
from fastapi import APIRouter, HTTPException, status, UploadFile, File
from pydantic import BaseModel, Field
from datetime import datetime

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared"))

from quiz_shared.models.session import QuizSession
from quiz_shared.models.question import Question
from quiz_shared.models.participant import Participant

from ..session.manager import SessionManager
from ..input.parser import InputParser
from ..retrieval.question_retriever import QuestionRetriever
from ..evaluation.evaluator import AnswerEvaluator
from ..rating.feedback import FeedbackService
from ..voice.transcriber import VoiceTranscriber


# Request/Response Models

class CreateSessionRequest(BaseModel):
    """Request to create a new quiz session."""
    max_questions: int = Field(default=10, ge=1, le=50, description="Number of questions")
    difficulty: str = Field(default="medium", pattern="^(easy|medium|hard)$")
    user_id: Optional[str] = None
    mode: str = Field(default="single", pattern="^(single|multiplayer)$")
    category: Optional[str] = Field(default=None, description="Category filter")
    ttl_minutes: int = Field(default=30, ge=10, le=120, description="Session expiry time")


class SessionResponse(BaseModel):
    """Response containing session data."""
    session_id: str
    mode: str
    phase: str
    max_questions: int
    current_difficulty: str
    category: Optional[str]
    participants: List[Participant]
    expires_at: datetime
    created_at: datetime


class StartQuizRequest(BaseModel):
    """Request to start the quiz."""
    pass


class SubmitInputRequest(BaseModel):
    """Request to submit user input (AI-powered parsing)."""
    input: str = Field(..., min_length=1, description="User's natural language input")
    participant_id: Optional[str] = Field(default=None, description="For multiplayer")


class InputResponse(BaseModel):
    """Response after processing input."""
    success: bool
    message: str
    session: SessionResponse
    current_question: Optional[Dict[str, Any]] = None
    evaluation: Optional[Dict[str, Any]] = None
    feedback_received: List[str] = Field(default_factory=list, description="Parsed intents")


class RateQuestionRequest(BaseModel):
    """Request to rate a question."""
    rating: int = Field(..., ge=1, le=5, description="Rating 1-5")
    feedback_text: Optional[str] = Field(default=None, description="Optional text feedback")
    participant_id: Optional[str] = Field(default=None, description="For multiplayer")


class AddParticipantRequest(BaseModel):
    """Request to add participant to multiplayer session."""
    display_name: str = Field(..., min_length=1, max_length=50)
    user_id: Optional[str] = None


# Router

router = APIRouter(prefix="/api/v1", tags=["Quiz Agent"])


# Dependency injection placeholders
# These will be set by main.py
session_manager: Optional[SessionManager] = None
input_parser: Optional[InputParser] = None
question_retriever: Optional[QuestionRetriever] = None
answer_evaluator: Optional[AnswerEvaluator] = None
feedback_service: Optional[FeedbackService] = None
voice_transcriber: Optional[VoiceTranscriber] = None


def init_dependencies(
    sm: SessionManager,
    ip: InputParser,
    qr: QuestionRetriever,
    ae: AnswerEvaluator,
    fs: FeedbackService,
    vt: VoiceTranscriber
):
    """Initialize service dependencies."""
    global session_manager, input_parser, question_retriever, answer_evaluator, feedback_service, voice_transcriber
    session_manager = sm
    input_parser = ip
    question_retriever = qr
    answer_evaluator = ae
    feedback_service = fs
    voice_transcriber = vt


# Helper functions

def session_to_response(session: QuizSession) -> SessionResponse:
    """Convert QuizSession to API response."""
    return SessionResponse(
        session_id=session.session_id,
        mode=session.mode,
        phase=session.phase,
        max_questions=session.max_questions,
        current_difficulty=session.current_difficulty,
        category=session.category,
        participants=session.participants,
        expires_at=session.expires_at,
        created_at=session.created_at
    )


def question_to_dict(question: Question) -> Dict[str, Any]:
    """Convert Question to dict for API response."""
    return {
        "id": question.id,
        "question": question.question,
        "type": question.type,
        "possible_answers": question.possible_answers,
        "difficulty": question.difficulty,
        "topic": question.topic,
        "category": question.category
        # Note: correct_answer is NOT included for security
    }


# Session Management Endpoints

@router.post("/sessions", response_model=SessionResponse, status_code=status.HTTP_201_CREATED)
async def create_session(request: CreateSessionRequest):
    """Create a new quiz session.

    Returns:
        SessionResponse with session_id and initial state
    """
    if not session_manager:
        raise HTTPException(status_code=500, detail="Service not initialized")

    try:
        session = session_manager.create_session(
            max_questions=request.max_questions,
            difficulty=request.difficulty,
            user_id=request.user_id,
            mode=request.mode,
            ttl_minutes=request.ttl_minutes
        )

        # Store category preference if provided
        if request.category:
            session.category = request.category
            session_manager.update_session(session)

        return session_to_response(session)

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to create session: {str(e)}")


@router.get("/sessions/{session_id}", response_model=SessionResponse)
async def get_session(session_id: str):
    """Get session state.

    Args:
        session_id: Session ID

    Returns:
        Current session state
    """
    if not session_manager:
        raise HTTPException(status_code=500, detail="Service not initialized")

    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    return session_to_response(session)


@router.delete("/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_session(session_id: str):
    """Delete a session.

    Args:
        session_id: Session ID
    """
    if not session_manager:
        raise HTTPException(status_code=500, detail="Service not initialized")

    success = session_manager.delete_session(session_id)
    if not success:
        raise HTTPException(status_code=404, detail="Session not found")


@router.post("/sessions/{session_id}/extend", response_model=SessionResponse)
async def extend_session(session_id: str, minutes: int = 30):
    """Extend session expiry time.

    Args:
        session_id: Session ID
        minutes: Minutes to extend (default: 30)

    Returns:
        Updated session state
    """
    if not session_manager:
        raise HTTPException(status_code=500, detail="Service not initialized")

    success = session_manager.extend_session(session_id, minutes)
    if not success:
        raise HTTPException(status_code=404, detail="Session not found")

    session = session_manager.get_session(session_id)
    return session_to_response(session)


# Game Flow Endpoints

@router.post("/sessions/{session_id}/start", response_model=InputResponse)
async def start_quiz(session_id: str, request: StartQuizRequest):
    """Start the quiz and get first question.

    Args:
        session_id: Session ID

    Returns:
        First question and updated session state
    """
    if not all([session_manager, question_retriever]):
        raise HTTPException(status_code=500, detail="Service not initialized")

    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    if session.phase != "idle":
        raise HTTPException(status_code=400, detail="Quiz already started")

    # Update phase
    session.phase = "asking"
    session.asked_question_ids = []

    # Get first question
    question = question_retriever.get_next_question(session)
    if not question:
        raise HTTPException(status_code=500, detail="Failed to retrieve question")

    session.current_question_id = question.id
    session.asked_question_ids.append(question.id)
    session_manager.update_session(session)

    return InputResponse(
        success=True,
        message="Quiz started",
        session=session_to_response(session),
        current_question=question_to_dict(question),
        feedback_received=[]
    )


@router.post("/sessions/{session_id}/input", response_model=InputResponse)
async def submit_input(session_id: str, request: SubmitInputRequest):
    """Submit user input (AI-powered natural language parsing).

    The AI agent parses complex inputs like:
    - "Paris" → answer
    - "London, too easy" → answer + rating
    - "Rome, make it harder" → answer + difficulty change
    - "skip, no more geography" → skip + preference change

    Args:
        session_id: Session ID
        request: User input

    Returns:
        Evaluation results and next question (if applicable)
    """
    if not all([session_manager, input_parser, question_retriever, answer_evaluator]):
        raise HTTPException(status_code=500, detail="Service not initialized")

    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    if session.phase not in ["asking", "awaiting_answer"]:
        raise HTTPException(status_code=400, detail="Not waiting for input")

    # Get current question
    from quiz_shared.database.chroma_client import ChromaDBClient
    chroma = ChromaDBClient()
    current_question = chroma.get_question(session.current_question_id)
    if not current_question:
        raise HTTPException(status_code=500, detail="Current question not found")

    # Parse input with AI agent
    intents = await input_parser.parse(
        user_input=request.input,
        current_question=current_question.question,
        phase=session.phase
    )

    feedback_received = []
    evaluation_result = None
    user_answer = None

    # Process intents
    for intent in intents:
        if intent.type == "answer":
            user_answer = intent.value
            # Evaluate answer
            result, score_delta = await answer_evaluator.evaluate(
                user_answer=user_answer,
                question=current_question,
                question_text=current_question.question
            )

            evaluation_result = {
                "user_answer": user_answer,
                "result": result,
                "points": score_delta,
                "correct_answer": str(current_question.correct_answer)
            }

            # Update participant score
            if request.participant_id:
                for p in session.participants:
                    if p.participant_id == request.participant_id:
                        p.score += score_delta
                        p.answered_count += 1
            elif session.participants:
                session.participants[0].score += score_delta
                session.participants[0].answered_count += 1

            feedback_received.append(f"answer: {result}")

        elif intent.type == "skip":
            evaluation_result = {
                "user_answer": "skipped",
                "result": "skipped",
                "points": 0.0,
                "correct_answer": str(current_question.correct_answer)
            }
            feedback_received.append("skipped question")

        elif intent.type == "rating":
            # Rating will be handled separately via rate endpoint
            feedback_received.append(f"rating: {intent.value}")

        elif intent.type == "difficulty_change":
            session.current_difficulty = intent.value
            feedback_received.append(f"difficulty: {intent.value}")

        elif intent.type == "preference_change":
            # Add to preferred/disliked topics
            if intent.value.startswith("-"):
                topic = intent.value[1:]
                if topic not in session.disliked_topics:
                    session.disliked_topics.append(topic)
                feedback_received.append(f"avoiding: {topic}")
            else:
                if intent.value not in session.preferred_topics:
                    session.preferred_topics.append(intent.value)
                feedback_received.append(f"preference: {intent.value}")

        elif intent.type == "category_change":
            session.category = intent.value
            feedback_received.append(f"category: {intent.value}")

    # Check if quiz is finished
    if len(session.asked_question_ids) >= session.max_questions:
        session.phase = "finished"
        session_manager.update_session(session)

        return InputResponse(
            success=True,
            message="Quiz completed!",
            session=session_to_response(session),
            current_question=None,
            evaluation=evaluation_result,
            feedback_received=feedback_received
        )

    # Get next question
    next_question = question_retriever.get_next_question(session)
    if not next_question:
        session.phase = "finished"
        session_manager.update_session(session)

        return InputResponse(
            success=True,
            message="No more questions available",
            session=session_to_response(session),
            current_question=None,
            evaluation=evaluation_result,
            feedback_received=feedback_received
        )

    # Update session with next question
    session.current_question_id = next_question.id
    session.asked_question_ids.append(next_question.id)
    session.phase = "asking"
    session_manager.update_session(session)

    return InputResponse(
        success=True,
        message="Input processed",
        session=session_to_response(session),
        current_question=question_to_dict(next_question),
        evaluation=evaluation_result,
        feedback_received=feedback_received
    )


@router.get("/sessions/{session_id}/question")
async def get_current_question(session_id: str):
    """Get current question without submitting input.

    Args:
        session_id: Session ID

    Returns:
        Current question data
    """
    if not session_manager:
        raise HTTPException(status_code=500, detail="Service not initialized")

    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    if not session.current_question_id:
        raise HTTPException(status_code=400, detail="No active question")

    from quiz_shared.database.chroma_client import ChromaDBClient
    chroma = ChromaDBClient()
    question = chroma.get_question(session.current_question_id)

    if not question:
        raise HTTPException(status_code=500, detail="Question not found")

    return {
        "question": question_to_dict(question),
        "progress": {
            "current": len(session.asked_question_ids),
            "total": session.max_questions
        }
    }


# Rating Endpoint

@router.post("/sessions/{session_id}/rate")
async def rate_question(session_id: str, request: RateQuestionRequest):
    """Rate the current or last question.

    Args:
        session_id: Session ID
        request: Rating (1-5) and optional feedback

    Returns:
        Success message
    """
    if not all([session_manager, feedback_service]):
        raise HTTPException(status_code=500, detail="Service not initialized")

    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    if not session.current_question_id:
        raise HTTPException(status_code=400, detail="No question to rate")

    # Determine user_id
    user_id = session.user_id
    if request.participant_id:
        # Find participant user_id
        for p in session.participants:
            if p.participant_id == request.participant_id:
                user_id = p.user_id or p.participant_id
                break

    user_id = user_id or "anonymous"

    # Submit rating
    success, message = await feedback_service.submit_rating(
        question_id=session.current_question_id,
        user_id=user_id,
        rating=request.rating,
        feedback_text=request.feedback_text
    )

    if not success:
        raise HTTPException(status_code=500, detail=message)

    return {
        "success": True,
        "message": message
    }


# Multiplayer Endpoints

@router.post("/sessions/{session_id}/participants", response_model=Participant)
async def add_participant(session_id: str, request: AddParticipantRequest):
    """Add participant to multiplayer session.

    Args:
        session_id: Session ID
        request: Participant details

    Returns:
        Created Participant object
    """
    if not session_manager:
        raise HTTPException(status_code=500, detail="Service not initialized")

    participant = session_manager.add_participant(
        session_id=session_id,
        display_name=request.display_name,
        user_id=request.user_id
    )

    if not participant:
        raise HTTPException(status_code=404, detail="Session not found")

    return participant


@router.delete("/sessions/{session_id}/participants/{participant_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_participant(session_id: str, participant_id: str):
    """Remove participant from session.

    Args:
        session_id: Session ID
        participant_id: Participant ID
    """
    if not session_manager:
        raise HTTPException(status_code=500, detail="Service not initialized")

    success = session_manager.remove_participant(session_id, participant_id)
    if not success:
        raise HTTPException(status_code=404, detail="Session or participant not found")


# Voice Endpoints

@router.post("/voice/transcribe")
async def transcribe_audio(
    audio: UploadFile = File(..., description="Audio file (mp3, wav, m4a, etc.)")
):
    """Transcribe audio file to text.

    Supports formats: mp3, mp4, mpeg, mpga, m4a, wav, webm, ogg
    Max file size: 25 MB

    Args:
        audio: Audio file upload

    Returns:
        Transcribed text and detected language

    Example:
        curl -X POST http://localhost:8002/api/v1/voice/transcribe \
          -F "audio=@answer.mp3"
    """
    if not voice_transcriber:
        raise HTTPException(status_code=500, detail="Voice service not initialized")

    try:
        # Validate format
        if not voice_transcriber.is_supported_format(audio.filename):
            raise HTTPException(
                status_code=400,
                detail=f"Unsupported audio format. Supported: {', '.join(VoiceTranscriber.SUPPORTED_FORMATS)}"
            )

        # Transcribe
        text, language = await voice_transcriber.transcribe(
            audio_file=audio.file,
            filename=audio.filename
        )

        return {
            "success": True,
            "text": text,
            "language": language,
            "filename": audio.filename
        }

    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=500, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Transcription failed: {str(e)}")


@router.post("/voice/submit/{session_id}", response_model=InputResponse)
async def transcribe_and_submit(
    session_id: str,
    audio: UploadFile = File(..., description="Audio file with quiz answer"),
    participant_id: Optional[str] = None
):
    """Transcribe audio and submit to quiz (one-step operation).

    This endpoint combines two operations:
    1. Transcribe audio to text using Whisper API
    2. Submit transcribed text to quiz with AI parsing

    Perfect for voice-based quiz interfaces.

    Args:
        session_id: Session ID
        audio: Audio file upload
        participant_id: Optional participant ID for multiplayer

    Returns:
        Same as /sessions/{id}/input endpoint

    Example:
        curl -X POST http://localhost:8002/api/v1/voice/submit/sess_abc123 \
          -F "audio=@answer.mp3" \
          -F "participant_id=p_12345678"
    """
    if not all([session_manager, voice_transcriber, input_parser, question_retriever, answer_evaluator]):
        raise HTTPException(status_code=500, detail="Service not initialized")

    # Get session
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    if session.phase not in ["asking", "awaiting_answer"]:
        raise HTTPException(status_code=400, detail="Not waiting for input")

    try:
        # Validate format
        if not voice_transcriber.is_supported_format(audio.filename):
            raise HTTPException(
                status_code=400,
                detail=f"Unsupported audio format. Supported: {', '.join(VoiceTranscriber.SUPPORTED_FORMATS)}"
            )

        # Get current question for context
        from quiz_shared.database.chroma_client import ChromaDBClient
        chroma = ChromaDBClient()
        current_question = chroma.get_question(session.current_question_id)
        if not current_question:
            raise HTTPException(status_code=500, detail="Current question not found")

        # Transcribe with quiz context
        transcribed_text = await voice_transcriber.transcribe_with_quiz_context(
            audio_file=audio.file,
            filename=audio.filename,
            current_question=current_question.question
        )

        # Now submit the transcribed text as regular input
        # Parse input with AI agent
        intents = await input_parser.parse(
            user_input=transcribed_text,
            current_question=current_question.question,
            phase=session.phase
        )

        feedback_received = [f"voice_input: {transcribed_text}"]
        evaluation_result = None
        user_answer = None

        # Process intents (same logic as /input endpoint)
        for intent in intents:
            if intent.type == "answer":
                user_answer = intent.value
                result, score_delta = await answer_evaluator.evaluate(
                    user_answer=user_answer,
                    question=current_question,
                    question_text=current_question.question
                )

                evaluation_result = {
                    "user_answer": user_answer,
                    "result": result,
                    "points": score_delta,
                    "correct_answer": str(current_question.correct_answer)
                }

                # Update participant score
                if participant_id:
                    for p in session.participants:
                        if p.participant_id == participant_id:
                            p.score += score_delta
                            p.answered_count += 1
                elif session.participants:
                    session.participants[0].score += score_delta
                    session.participants[0].answered_count += 1

                feedback_received.append(f"answer: {result}")

            elif intent.type == "skip":
                evaluation_result = {
                    "user_answer": "skipped",
                    "result": "skipped",
                    "points": 0.0,
                    "correct_answer": str(current_question.correct_answer)
                }
                feedback_received.append("skipped question")

            elif intent.type == "difficulty_change":
                session.current_difficulty = intent.value
                feedback_received.append(f"difficulty: {intent.value}")

            elif intent.type == "preference_change":
                if intent.value.startswith("-"):
                    topic = intent.value[1:]
                    if topic not in session.disliked_topics:
                        session.disliked_topics.append(topic)
                    feedback_received.append(f"avoiding: {topic}")
                else:
                    if intent.value not in session.preferred_topics:
                        session.preferred_topics.append(intent.value)
                    feedback_received.append(f"preference: {intent.value}")

            elif intent.type == "category_change":
                session.category = intent.value
                feedback_received.append(f"category: {intent.value}")

        # Check if quiz is finished
        if len(session.asked_question_ids) >= session.max_questions:
            session.phase = "finished"
            session_manager.update_session(session)

            return InputResponse(
                success=True,
                message="Quiz completed!",
                session=session_to_response(session),
                current_question=None,
                evaluation=evaluation_result,
                feedback_received=feedback_received
            )

        # Get next question
        next_question = question_retriever.get_next_question(session)
        if not next_question:
            session.phase = "finished"
            session_manager.update_session(session)

            return InputResponse(
                success=True,
                message="No more questions available",
                session=session_to_response(session),
                current_question=None,
                evaluation=evaluation_result,
                feedback_received=feedback_received
            )

        # Update session with next question
        session.current_question_id = next_question.id
        session.asked_question_ids.append(next_question.id)
        session.phase = "asking"
        session_manager.update_session(session)

        return InputResponse(
            success=True,
            message="Voice input processed",
            session=session_to_response(session),
            current_question=question_to_dict(next_question),
            evaluation=evaluation_result,
            feedback_received=feedback_received
        )

    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=500, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Voice submission failed: {str(e)}")


# Health Check

@router.get("/health")
async def health_check():
    """Health check endpoint."""
    return {
        "status": "healthy",
        "service": "quiz-agent",
        "timestamp": datetime.now().isoformat()
    }
