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
from ..tts.service import TTSService


# Request/Response Models

class CreateSessionRequest(BaseModel):
    """Request to create a new quiz session."""
    max_questions: int = Field(default=10, ge=1, le=50, description="Number of questions")
    difficulty: str = Field(default="medium", pattern="^(easy|medium|hard|random)$", description="Difficulty level or 'random' for varying difficulty per question")
    user_id: Optional[str] = None
    mode: str = Field(default="single", pattern="^(single|multiplayer)$")
    category: Optional[str] = Field(default=None, description="Category filter")
    language: str = Field(default="en", pattern="^[a-z]{2}$", description="Language code (ISO 639-1)")
    ttl_minutes: int = Field(default=30, ge=10, le=120, description="Session expiry time")


class SessionResponse(BaseModel):
    """Response containing session data."""
    session_id: str
    mode: str
    phase: str
    max_questions: int
    current_difficulty: str
    category: Optional[str]
    language: str
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
    audio: Optional[Dict[str, Any]] = Field(default=None, description="Audio URLs when audio=true")


class RateQuestionRequest(BaseModel):
    """Request to rate a question."""
    rating: int = Field(..., ge=1, le=5, description="Rating 1-5")
    feedback_text: Optional[str] = Field(default=None, description="Optional text feedback")
    participant_id: Optional[str] = Field(default=None, description="For multiplayer")


class AddParticipantRequest(BaseModel):
    """Request to add participant to multiplayer session."""
    display_name: str = Field(..., min_length=1, max_length=50)
    user_id: Optional[str] = None


class SynthesizeTTSRequest(BaseModel):
    """Request to synthesize text to speech."""
    text: str = Field(..., min_length=1, max_length=1000, description="Text to synthesize")
    voice: Optional[str] = Field(default="nova", description="Voice name (nova, shimmer, onyx)")
    format: Optional[str] = Field(default="opus", description="Audio format (opus, mp3, aac)")


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
tts_service: Optional[TTSService] = None
translation_service: Optional[Any] = None  # TranslationService
chroma_client: Optional[Any] = None  # ChromaDBClient


def init_dependencies(
    sm: SessionManager,
    ip: InputParser,
    qr: QuestionRetriever,
    ae: AnswerEvaluator,
    fs: FeedbackService,
    vt: VoiceTranscriber,
    tts: TTSService,
    ts: Any,  # TranslationService
    cc: Optional[Any] = None  # ChromaDBClient
):
    """Initialize service dependencies."""
    global session_manager, input_parser, question_retriever, answer_evaluator, feedback_service, voice_transcriber, tts_service, translation_service, chroma_client
    session_manager = sm
    input_parser = ip
    question_retriever = qr
    answer_evaluator = ae
    feedback_service = fs
    voice_transcriber = vt
    tts_service = tts
    translation_service = ts
    chroma_client = cc


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
        language=session.language,
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

        # Store language and category preferences
        session.language = request.language
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
async def start_quiz(session_id: str, request: StartQuizRequest, audio: bool = False):
    """Start the quiz and get first question.

    Args:
        session_id: Session ID
        audio: Include audio URLs in response (default: False)

    Returns:
        First question and updated session state (with audio URLs if audio=true)

    Example:
        POST /api/v1/sessions/sess_123/start?audio=true
    """
    if not all([session_manager, question_retriever]):
        raise HTTPException(status_code=500, detail="Service not initialized")

    try:
        session = session_manager.get_session(session_id)
        if not session:
            raise HTTPException(status_code=404, detail="Session not found or expired")

        if session.phase != "idle":
            raise HTTPException(status_code=400, detail="Quiz already started")

        # Update phase
        session.phase = "asking"
        session.asked_question_ids = []

        # Get first question
        print(f"DEBUG: Getting next question for session {session_id}, difficulty: {session.current_difficulty}")
        try:
            question = question_retriever.get_next_question(session)
        except Exception as e:
            print(f"ERROR: Exception in get_next_question: {e}")
            import traceback
            traceback.print_exc()
            raise HTTPException(status_code=500, detail=f"Failed to retrieve question: {str(e)}")
        
        if not question:
            print(f"ERROR: get_next_question returned None for session {session_id}")
            # Check database status using the shared chroma_client
            if chroma_client:
                total_count = chroma_client.count_questions()
            else:
                total_count = 0
            
            if total_count == 0:
                error_detail = (
                    "The question database is empty. "
                    "Please generate or import questions first:\n"
                    "1. Start the question-generator app: cd apps/question-generator && python -m app.main\n"
                    "2. Generate questions via the API or use the web interface\n"
                    "3. Then try starting the quiz again"
                )
            else:
                error_detail = (
                    f"No questions match the criteria. "
                    f"Database has {total_count} questions, but none match:\n"
                    f"- Difficulty: {session.current_difficulty}\n"
                    f"- Type: text\n"
                    f"- Category: not in ['children']\n\n"
                    "Try a different difficulty or ensure questions are properly categorized."
                )
            
            raise HTTPException(status_code=500, detail=error_detail)

        session.current_question_id = question.id
        session.asked_question_ids.append(question.id)
        session_manager.update_session(session)

        # Build response with optional audio URLs
        audio_info = None
        if audio:
            audio_info = {
                "question_url": f"/api/v1/sessions/{session_id}/question/audio",
                "format": "opus"
            }

        return InputResponse(
            success=True,
            message="Quiz started",
            session=session_to_response(session),
            current_question=question_to_dict(question),
            feedback_received=[],
            audio=audio_info
        )
    except HTTPException:
        raise
    except Exception as e:
        print(f"ERROR: Unexpected exception in start_quiz: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Failed to start quiz: {str(e)}")


@router.post("/sessions/{session_id}/input", response_model=InputResponse)
async def submit_input(session_id: str, request: SubmitInputRequest, audio: bool = False):
    """Submit user input (AI-powered natural language parsing).

    The AI agent parses complex inputs like:
    - "Paris" → answer
    - "London, too easy" → answer + rating
    - "Rome, make it harder" → answer + difficulty change
    - "skip, no more geography" → skip + preference change

    Args:
        session_id: Session ID
        request: User input
        audio: Include audio URLs in response (default: False)

    Returns:
        Evaluation results and next question (with audio URLs if audio=true)
    """
    if not all([session_manager, input_parser, question_retriever, answer_evaluator]):
        raise HTTPException(status_code=500, detail="Service not initialized")

    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    if session.phase not in ["asking", "awaiting_answer"]:
        raise HTTPException(status_code=400, detail="Not waiting for input")

    # Get current question
    if not chroma_client:
        raise HTTPException(status_code=500, detail="ChromaDB client not initialized")
    current_question = chroma_client.get_question(session.current_question_id)
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
        intent_type = intent.get("intent_type")
        extracted_data = intent.get("extracted_data", {})

        if intent_type == "answer":
            user_answer = extracted_data.get("answer")
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

        elif intent_type == "skip":
            evaluation_result = {
                "user_answer": "skipped",
                "result": "skipped",
                "points": 0.0,
                "correct_answer": str(current_question.correct_answer)
            }
            feedback_received.append("skipped question")

        elif intent_type == "rating":
            # Rating will be handled separately via rate endpoint
            rating_value = extracted_data.get("rating")
            feedback_received.append(f"rating: {rating_value}")

        elif intent_type == "difficulty_change":
            difficulty = extracted_data.get("difficulty")
            session.current_difficulty = difficulty
            feedback_received.append(f"difficulty: {difficulty}")

        elif intent_type == "preference_change":
            # Add to preferred/disliked topics
            topic = extracted_data.get("topic", "")
            if topic.startswith("-"):
                topic = topic[1:]
                if topic not in session.disliked_topics:
                    session.disliked_topics.append(topic)
                feedback_received.append(f"avoiding: {topic}")
            else:
                if topic not in session.preferred_topics:
                    session.preferred_topics.append(topic)
                feedback_received.append(f"preference: {topic}")

        elif intent_type == "category_change":
            category = extracted_data.get("category")
            session.category = category
            feedback_received.append(f"category: {category}")

    # Build audio info for response
    audio_info = None
    if audio and evaluation_result:
        result_type = evaluation_result.get("result", "")
        audio_info = {
            "feedback_url": f"/api/v1/sessions/{session_id}/feedback/{result_type}/audio",
            "format": "opus"
        }

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
            feedback_received=feedback_received,
            audio=audio_info
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
            feedback_received=feedback_received,
            audio=audio_info
        )

    # Update session with next question
    session.current_question_id = next_question.id
    session.asked_question_ids.append(next_question.id)
    session.phase = "asking"
    session_manager.update_session(session)

    # Add question URL to audio info
    if audio:
        if not audio_info:
            audio_info = {}
        audio_info["question_url"] = f"/api/v1/sessions/{session_id}/question/audio"
        audio_info["format"] = "opus"

    return InputResponse(
        success=True,
        message="Input processed",
        session=session_to_response(session),
        current_question=question_to_dict(next_question),
        evaluation=evaluation_result,
        feedback_received=feedback_received,
        audio=audio_info
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

    if not chroma_client:
        raise HTTPException(status_code=500, detail="ChromaDB client not initialized")
    question = chroma_client.get_question(session.current_question_id)

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
    participant_id: Optional[str] = None,
    include_audio: bool = True
):
    """Transcribe audio and submit to quiz (one-step operation).

    This endpoint combines two operations:
    1. Transcribe audio to text using Whisper API
    2. Submit transcribed text to quiz with AI parsing

    Perfect for voice-based quiz interfaces.

    Args:
        session_id: Session ID
        audio: Audio file (mp3, m4a, wav, webm, etc.)
        participant_id: Optional participant ID (for multiplayer)
        include_audio: Include audio URLs in response (default: True for voice clients)

    Returns:
        Evaluation + next question + audio URLs (feedback + next question audio)

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
        if not chroma_client:
            raise HTTPException(status_code=500, detail="ChromaDB client not initialized")
        current_question = chroma_client.get_question(session.current_question_id)
        if not current_question:
            raise HTTPException(status_code=500, detail="Current question not found")

        # Transcribe with quiz context
        transcribed_text = await voice_transcriber.transcribe_with_quiz_context(
            audio_file=audio.file,
            filename=audio.filename,
            current_question=current_question.question
        )

        # Validate transcription is not empty
        if not transcribed_text or len(transcribed_text.strip()) < 2:
            print(f"⚠️ Empty transcription detected for session {session_id}")
            raise HTTPException(
                status_code=400,
                detail="No speech detected in audio. Please record your answer clearly and try again."
            )

        print(f"✅ Transcribed: '{transcribed_text}'")

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
            intent_type = intent.get("intent_type")
            extracted_data = intent.get("extracted_data", {})

            if intent_type == "answer":
                user_answer = extracted_data.get("answer")
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

            elif intent_type == "skip":
                evaluation_result = {
                    "user_answer": "skipped",
                    "result": "skipped",
                    "points": 0.0,
                    "correct_answer": str(current_question.correct_answer)
                }
                feedback_received.append("skipped question")

            elif intent_type == "difficulty_change":
                difficulty = extracted_data.get("difficulty")
                session.current_difficulty = difficulty
                feedback_received.append(f"difficulty: {difficulty}")

            elif intent_type == "preference_change":
                topic = extracted_data.get("topic", "")
                if topic.startswith("-"):
                    topic = topic[1:]
                    if topic not in session.disliked_topics:
                        session.disliked_topics.append(topic)
                    feedback_received.append(f"avoiding: {topic}")
                else:
                    if topic not in session.preferred_topics:
                        session.preferred_topics.append(topic)
                    feedback_received.append(f"preference: {topic}")

            elif intent_type == "category_change":
                category = extracted_data.get("category")
                session.category = category
                feedback_received.append(f"category: {category}")

        # Build audio info for voice response
        audio_info = None
        if include_audio and evaluation_result:
            result_type = evaluation_result.get("result", "")
            audio_info = {
                "feedback_url": f"/api/v1/sessions/{session_id}/feedback/{result_type}/audio",
                "format": "opus"
            }

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
                feedback_received=feedback_received,
                audio=audio_info
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
                feedback_received=feedback_received,
                audio=audio_info
            )

        # Update session with next question
        session.current_question_id = next_question.id
        session.asked_question_ids.append(next_question.id)
        session.phase = "asking"
        session_manager.update_session(session)

        # Add question URL to audio info
        if include_audio:
            if not audio_info:
                audio_info = {}
            audio_info["question_url"] = f"/api/v1/sessions/{session_id}/question/audio"
            audio_info["format"] = "opus"

        return InputResponse(
            success=True,
            message="Voice input processed",
            session=session_to_response(session),
            current_question=question_to_dict(next_question),
            evaluation=evaluation_result,
            feedback_received=feedback_received,
            audio=audio_info
        )

    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=500, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Voice submission failed: {str(e)}")


# Text-to-Speech (TTS) Endpoints

@router.post("/tts/synthesize")
async def synthesize_tts(request: SynthesizeTTSRequest):
    """Generate speech audio from text (generic TTS).

    Args:
        request: TTS synthesis request with text, voice, and format

    Returns:
        Audio file in requested format (Opus by default)

    Example:
        curl -X POST http://localhost:8002/api/v1/tts/synthesize \
          -H "Content-Type: application/json" \
          -d '{"text": "What is the capital of France?", "voice": "nova"}' \
          --output question.opus
    """
    if not tts_service:
        raise HTTPException(status_code=500, detail="TTS service not initialized")

    try:
        audio_data = await tts_service.synthesize(
            text=request.text,
            voice=request.voice,
            use_cache=True
        )

        from fastapi.responses import Response
        return Response(
            content=audio_data,
            media_type=f"audio/{request.format}",
            headers={
                "Content-Disposition": f'attachment; filename="speech.{request.format}"'
            }
        )

    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"TTS synthesis failed: {str(e)}")


@router.get("/sessions/{session_id}/question/audio")
async def get_question_audio(session_id: str):
    """Get audio for current question in session (cached).

    Args:
        session_id: Session ID

    Returns:
        Audio file of current question in Opus format

    Example:
        curl http://localhost:8002/api/v1/sessions/sess_abc123/question/audio \
          --output question.opus
    """
    if not all([session_manager, tts_service, chroma_client]):
        raise HTTPException(status_code=500, detail="Services not initialized")

    # Get session
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    # Get current question
    if not session.current_question_id:
        raise HTTPException(status_code=400, detail="No active question in session")

    current_question = chroma_client.get_question(session.current_question_id)
    if not current_question:
        raise HTTPException(status_code=404, detail="Current question not found")

    try:
        # Translate question to session language if needed
        question_text = current_question.question

        print(f"DEBUG: translation_service = {translation_service}")
        print(f"DEBUG: session.language = {session.language}")

        if translation_service and session.language != "en":
            print(f"DEBUG: Translating question to {session.language}")
            question_text = await translation_service.translate_question(
                question=current_question.question,
                target_language=session.language
            )
            print(f"DEBUG: Translated text = {question_text}")
        else:
            print(f"DEBUG: No translation needed (translation_service={translation_service is not None}, lang={session.language})")

        # Generate/retrieve cached audio
        audio_data = await tts_service.synthesize_question(
            question_text=question_text
        )

        from fastapi.responses import Response
        return Response(
            content=audio_data,
            media_type="audio/opus",
            headers={
                "Content-Disposition": 'attachment; filename="question.opus"',
                "Cache-Control": "public, max-age=3600"  # Cache for 1 hour
            }
        )

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Audio generation failed: {str(e)}")


@router.get("/tts/feedback/{result}")
async def get_feedback_audio(result: str, variant: Optional[int] = None):
    """Get pre-cached feedback audio (instant response).

    Args:
        result: Evaluation result (correct, incorrect, partially_correct, skipped)
        variant: Optional specific phrase variant (0, 1, 2, ...). Random if not specified.

    Returns:
        Pre-generated audio file in Opus format

    Example:
        curl http://localhost:8002/api/v1/tts/feedback/correct \
          --output feedback.opus
    """
    if not tts_service:
        raise HTTPException(status_code=500, detail="TTS service not initialized")

    # Validate result
    valid_results = ["correct", "incorrect", "partially_correct", "partially_incorrect", "skipped"]
    if result not in valid_results:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid result. Must be one of: {', '.join(valid_results)}"
        )

    try:
        # Get pre-cached feedback audio
        audio_data = await tts_service.get_feedback_audio(result, variant)

        if not audio_data:
            raise HTTPException(
                status_code=404,
                detail=f"Feedback audio not found for result '{result}'. Pre-generation may have failed."
            )

        from fastapi.responses import Response
        return Response(
            content=audio_data,
            media_type="audio/opus",
            headers={
                "Content-Disposition": f'attachment; filename="feedback_{result}.opus"',
                "Cache-Control": "public, max-age=86400"  # Cache for 24 hours
            }
        )

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to retrieve feedback audio: {str(e)}")


@router.get("/sessions/{session_id}/feedback/{result}/audio")
async def get_session_feedback_audio(session_id: str, result: str):
    """Get feedback audio in session's language.

    Args:
        session_id: Session ID
        result: Evaluation result (correct, incorrect, etc.)

    Returns:
        Feedback audio in session's preferred language
    """
    if not all([session_manager, tts_service, translation_service]):
        raise HTTPException(status_code=500, detail="Services not initialized")

    # Get session to know the language
    session = session_manager.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found or expired")

    # Validate result
    valid_results = ["correct", "incorrect", "partially_correct", "partially_incorrect", "skipped"]
    if result not in valid_results:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid result. Must be one of: {', '.join(valid_results)}"
        )

    try:
        # Import the feedback messages function
        from ..translation import get_feedback_message

        # Get feedback message in session language
        feedback_text = get_feedback_message(result, session.language)

        # Generate audio
        audio_data = await tts_service.synthesize(feedback_text, use_cache=True)

        from fastapi.responses import Response
        return Response(
            content=audio_data,
            media_type="audio/opus",
            headers={
                "Content-Disposition": f'attachment; filename="feedback_{result}_{session.language}.opus"',
                "Cache-Control": "public, max-age=3600"  # Cache for 1 hour
            }
        )

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to generate feedback audio: {str(e)}")


# Health Check

@router.get("/health")
async def health_check():
    """Health check endpoint."""
    return {
        "status": "healthy",
        "service": "quiz-agent",
        "timestamp": datetime.now().isoformat()
    }
