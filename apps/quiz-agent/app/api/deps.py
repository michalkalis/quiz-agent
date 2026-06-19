"""Shared dependencies, models, and helpers for REST API routes."""

from typing import Optional, List, Dict, Any
from pydantic import BaseModel, Field
from datetime import datetime
from fastapi import Request

from quiz_shared.models.session import QuizSession
from quiz_shared.models.participant import Participant
from quiz_shared.database.question_store import QuestionStore

from ..session.manager import SessionManager
from ..retrieval.question_retriever import QuestionRetriever
from ..rating.feedback import FeedbackService
from ..voice.transcriber import VoiceTranscriber
from ..tts.service import TTSService
from ..usage.tracker import UsageTracker
from ..auth.tokens import TokenService
from ..auth.refresh import RefreshTokenStore
from ..auth.attest_challenge import ChallengeStore
from ..quiz.flow import QuizFlowService, FlowResult
from ..serializers import (
    question_to_dict as question_to_dict,
    question_to_dict_translated as question_to_dict_translated,
)


# ── Request/Response Models ──────────────────────────────────────────────────


class CreateSessionRequest(BaseModel):
    """Request to create a new quiz session."""

    max_questions: int = Field(
        default=10, ge=1, le=50, description="Number of questions"
    )
    difficulty: str = Field(
        default="medium",
        pattern="^(easy|medium|hard|random)$",
        description="Difficulty level or 'random' for varying difficulty per question",
    )
    user_id: Optional[str] = None
    mode: str = Field(default="single", pattern="^(single|multiplayer)$")
    category: Optional[str] = Field(default=None, description="Category filter")
    language: str = Field(
        default="en", pattern="^[a-z]{2}$", description="Language code (ISO 639-1)"
    )
    ttl_minutes: int = Field(
        default=30, ge=10, le=120, description="Session expiry time"
    )


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

    excluded_question_ids: Optional[List[str]] = Field(
        default=None,
        description="Question IDs to exclude from selection (client-side history)",
    )


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
    feedback_received: List[str] = Field(
        default_factory=list, description="Parsed intents"
    )
    audio: Optional[Dict[str, Any]] = Field(
        default=None, description="Audio URLs when audio=true"
    )


class RateQuestionRequest(BaseModel):
    """Request to rate a question."""

    rating: int = Field(..., ge=1, le=5, description="Rating 1-5")
    feedback_text: Optional[str] = Field(
        default=None, description="Optional text feedback"
    )
    participant_id: Optional[str] = Field(default=None, description="For multiplayer")


class FlagQuestionRequest(BaseModel):
    """Request to flag a question as potentially incorrect."""

    reason: Optional[str] = Field(
        default=None,
        max_length=500,
        description="Why the user thinks the answer is wrong",
    )
    participant_id: Optional[str] = Field(default=None, description="For multiplayer")


class AddParticipantRequest(BaseModel):
    """Request to add participant to multiplayer session."""

    display_name: str = Field(..., min_length=1, max_length=50)
    user_id: Optional[str] = None


class SynthesizeTTSRequest(BaseModel):
    """Request to synthesize text to speech."""

    text: str = Field(
        ..., min_length=1, max_length=1000, description="Text to synthesize"
    )
    voice: Optional[str] = Field(
        default="nova", description="Voice name (nova, shimmer, onyx)"
    )
    format: Optional[str] = Field(
        default="opus", description="Audio format (opus, mp3, aac)"
    )


class ElevenLabsTokenResponse(BaseModel):
    """Response with single-use ElevenLabs token for client-side WebSocket auth."""

    token: str = Field(
        description="Single-use token for ElevenLabs WebSocket connection (expires in 15 minutes)"
    )


class RefreshRequest(BaseModel):
    """Request to rotate a refresh token (issue #60, task 60.4)."""

    refresh_token: str = Field(
        ..., min_length=1, description="The opaque refresh token"
    )


class AttestChallengeResponse(BaseModel):
    """One-time challenge for App Attest (issue #60 Part B, task 60.10)."""

    challenge: str = Field(
        description="Single-use random value the device signs over; expires soon"
    )
    expires_in: int = Field(description="Challenge lifetime in seconds")


class AuthTokenResponse(BaseModel):
    """Token pair returned by anon-bootstrap and refresh (issue #60, task 60.4)."""

    access_token: str = Field(description="Short-lived JWT (bearer) for API calls")
    refresh_token: str = Field(
        description="Opaque rotating refresh token; store securely, send once on refresh"
    )
    token_type: str = Field(default="bearer")
    expires_in: int = Field(description="Access-token lifetime in seconds")
    anon_id: str = Field(description="The server-assigned anonymous subject id")


# ── Dependency Injection (FastAPI Depends) ───────────────────────────────────
# Services are stored on app.state during lifespan startup (see main.py).
# These functions retrieve them for use in route signatures via Depends().


def get_session_manager(request: Request) -> SessionManager:
    return request.app.state.session_manager


def get_question_retriever(request: Request) -> QuestionRetriever:
    return request.app.state.question_retriever


def get_feedback_service(request: Request) -> FeedbackService:
    return request.app.state.feedback_service


def get_voice_transcriber(request: Request) -> VoiceTranscriber:
    return request.app.state.voice_transcriber


def get_tts_service(request: Request) -> TTSService:
    return request.app.state.tts_service


def get_usage_tracker(request: Request) -> Optional[UsageTracker]:
    # None when DATABASE_URL is unset (usage persistence disabled); callers guard.
    return request.app.state.usage_tracker


def get_token_service(request: Request) -> Optional[TokenService]:
    # None when DB or AUTH_JWT_SECRET is unset (auth disabled); callers return 503.
    return getattr(request.app.state, "token_service", None)


def get_refresh_store(request: Request) -> Optional[RefreshTokenStore]:
    return getattr(request.app.state, "refresh_store", None)


def get_challenge_store(request: Request) -> Optional[ChallengeStore]:
    # None when DB is unset (App Attest disabled); callers return 503.
    return getattr(request.app.state, "challenge_store", None)


def get_auth_sessionmaker(request: Request):
    """Sessionmaker dedicated to the auth tables (None when auth is disabled)."""
    return getattr(request.app.state, "auth_sessionmaker", None)


def get_quiz_flow(request: Request) -> QuizFlowService:
    return request.app.state.quiz_flow


def get_question_store(request: Request) -> QuestionStore:
    return request.app.state.question_store


def get_chroma_client(request: Request):
    """Deprecated — prefer `get_question_store`. Kept for the question health monitor."""
    return request.app.state.chroma_client


def get_translation_service(request: Request):
    return request.app.state.translation_service


# ── Helper Functions ─────────────────────────────────────────────────────────


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
        created_at=session.created_at,
    )


def flow_to_response(flow_result: FlowResult, session: Any) -> InputResponse:
    """Convert a QuizFlowService result to an InputResponse."""
    return InputResponse(
        success=True,
        message=flow_result.message,
        session=session_to_response(session),
        current_question=flow_result.next_question_dict,
        evaluation=flow_result.evaluation,
        feedback_received=flow_result.feedback_received,
        audio=flow_result.audio_info,
    )
