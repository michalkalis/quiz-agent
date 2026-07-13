"""Shared dependencies, models, and helpers for REST API routes."""

from typing import Optional, List, Dict, Any
from pydantic import BaseModel, Field
from datetime import datetime, date
from fastapi import Depends, Request

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
from ..auth.app_attest import AppAttestService
from ..auth.apple import AppleIdentityVerifier
from ..auth.apple_oauth import AppleOAuthClient
from ..auth.apple_secrets import AppleTokenCipher
from ..auth.identity import AuthSubject, require_bearer_or_grace
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
    category: Optional[str] = Field(
        default=None,
        description="Legacy single-category filter (pre-#82 clients); "
        "superseded by `categories`",
    )
    categories: Optional[List[str]] = Field(
        default=None,
        description="Category filter, multi-select (#82); empty/absent = all",
    )
    language: str = Field(
        default="en", pattern="^[a-z]{2}$", description="Language code (ISO 639-1)"
    )
    include_images: bool = Field(
        default=False,
        description="Whether image-type questions may be served (#68, default off)",
    )
    pack_id: Optional[str] = Field(
        default=None,
        description=(
            "Play a delivered custom quiz pack (#95): scopes the whole session to "
            "this pack's questions and bypasses the free monthly quota. Omit for a "
            "normal quiz from the shared corpus."
        ),
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


class UsageResponse(BaseModel):
    """Freemium usage + entitlement snapshot for ``GET /usage/{id}`` (issue #93).

    Additive over the pre-#93 raw dict: ``subscription_status`` + ``credit_balance``
    are new; the legacy fields are unchanged so an un-updated iOS client keeps
    working (it just sees the 30-question cap and no pack UI). ``questions_limit``
    / ``remaining`` are ``None`` when the account is unlimited (entitled sub or
    the legacy premium flag)."""

    user_id: str
    is_premium: bool = Field(
        description="Legacy premium flag (daily_usage.is_premium); no longer gates"
    )
    questions_used: int
    questions_limit: Optional[int] = Field(
        description="Free monthly cap, or null when unlimited"
    )
    remaining: Optional[int] = Field(
        description="Free questions left this month, or null when unlimited"
    )
    resets_at: str = Field(description="ISO-8601 UTC start of next month")
    subscription_status: str = Field(
        description="Stored subscription status (active|grace|expired) or 'none'"
    )
    credit_balance: int = Field(
        description="Pack-credit balance = SUM(credit_ledger.delta)"
    )


class RefreshRequest(BaseModel):
    """Request to rotate a refresh token (issue #60, task 60.4)."""

    refresh_token: str = Field(
        ..., min_length=1, description="The opaque refresh token"
    )


class AnonBootstrapRequest(BaseModel):
    """Optional App Attest credentials carried by anon-bootstrap (#60.12).

    All fields are optional so the Part A client (empty body) and the dev/test
    path (``APP_ATTEST_REQUIRED=off``) keep minting plainly. A device sends
    exactly one credential against a fresh ``challenge``:

    - first launch → ``attestation`` (proves a real key on a real device); the
      server mints the identity and binds this key to it 1:1, forever.
    - re-bootstrap → ``assertion`` (proves possession of that same key); the
      server returns tokens for the *already-bound* identity and never mints a
      new one.

    Bytes travel as base64 strings since JSON cannot carry raw bytes.
    """

    key_id: Optional[str] = Field(
        default=None, description="base64 App Attest keyId (SHA256 of the public key)"
    )
    attestation: Optional[str] = Field(
        default=None, description="base64 CBOR attestation object (first launch)"
    )
    assertion: Optional[str] = Field(
        default=None, description="base64 CBOR assertion object (re-bootstrap)"
    )
    challenge: Optional[str] = Field(
        default=None, description="The challenge returned by /auth/attest-challenge"
    )


class AttestChallengeResponse(BaseModel):
    """One-time challenge for App Attest (issue #60 Part B, task 60.10)."""

    challenge: str = Field(
        description="Single-use random value the device signs over; expires soon"
    )
    expires_in: int = Field(description="Challenge lifetime in seconds")


class AuthTokenResponse(BaseModel):
    """Token pair returned by anon-bootstrap and refresh (issue #60, task 60.4).

    Reused by ``/auth/apple`` (#61): after Sign in with Apple the subject is the
    new ``users.id``, returned in the (legacy-named) ``anon_id`` field — it always
    carries the JWT ``sub`` the client should store as its upgrade anchor."""

    access_token: str = Field(description="Short-lived JWT (bearer) for API calls")
    refresh_token: str = Field(
        description="Opaque rotating refresh token; store securely, send once on refresh"
    )
    token_type: str = Field(default="bearer")
    expires_in: int = Field(description="Access-token lifetime in seconds")
    anon_id: str = Field(description="The server-assigned subject id (JWT sub)")


class AppleSignInUser(BaseModel):
    """First-authorization profile Apple hands the *client* exactly once, via the
    native credential only (never inside the id_token). Both fields are optional —
    absent on every sign-in after the first. ``name`` is the display name the
    client assembles from Apple's name components (decision F5)."""

    name: Optional[str] = Field(
        default=None, description="Display name (first auth only)"
    )
    email: Optional[str] = Field(
        default=None,
        description="Email (first auth only; the verified id_token email is preferred)",
    )


class AppleSignInRequest(BaseModel):
    """Body for ``POST /auth/apple`` — Sign in with Apple (issue #61, task 61.4)."""

    identity_token: str = Field(
        ..., min_length=1, description="Apple id_token (JWT) from the native credential"
    )
    authorization_code: str = Field(
        ...,
        min_length=1,
        description="Single-use Apple authorization code (exchanged immediately, F10)",
    )
    raw_nonce: str = Field(
        ...,
        min_length=1,
        description=(
            "The raw nonce the client generated; the id_token nonce claim must equal "
            "base64url-nopad(sha256(raw_nonce)) (decision F6)"
        ),
    )
    user: Optional[AppleSignInUser] = Field(
        default=None, description="First-login name/email Apple returns only once"
    )


class AccountUsageRecord(BaseModel):
    """One UTC day of an account's question usage, for the GDPR export (61.5)."""

    usage_date: date = Field(description="The UTC day this usage is counted for")
    questions_count: int = Field(description="Questions consumed that day")
    is_premium: bool = Field(description="Whether premium was active that day")


class AccountExportResponse(BaseModel):
    """GDPR Art. 20 data export for a Sign in with Apple account (issue #61, 61.5).

    Carries only the caller's own data — profile, full usage history, and derived
    premium. It deliberately has **no field** for the encrypted Apple refresh token
    or any other secret, so the export cannot leak one."""

    apple_sub: str = Field(description="Apple's stable per-app subject id (anchor)")
    email: Optional[str] = Field(default=None, description="Email, if Apple shared one")
    full_name: Optional[str] = Field(
        default=None, description="Name from first sign-in (F5)"
    )
    created_at: datetime = Field(description="When the account was created")
    is_premium: bool = Field(
        description="Derived premium state as of today (F8: no plan tier)"
    )
    usage: List[AccountUsageRecord] = Field(
        description="Per-day usage history, oldest first"
    )


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


def require_auth_or_grace(
    request: Request,
    token_service: Optional[TokenService] = Depends(get_token_service),
) -> AuthSubject:
    """Gate high-cost AI endpoints (#65): require a valid bearer, or pass during
    the legacy grace window (loudly logged, ``authenticated=False``). NOT a hard
    auth gate while grace is on — callers needing a verified subject must check
    ``subject.authenticated``. Thin FastAPI wrapper — see
    ``auth.identity.require_bearer_or_grace`` for the authority rule."""
    return require_bearer_or_grace(request, token_service)


def get_refresh_store(request: Request) -> Optional[RefreshTokenStore]:
    return getattr(request.app.state, "refresh_store", None)


def get_challenge_store(request: Request) -> Optional[ChallengeStore]:
    # None when DB is unset (App Attest disabled); callers return 503.
    return getattr(request.app.state, "challenge_store", None)


def get_app_attest_service(request: Request) -> Optional[AppAttestService]:
    # None when APP_ATTEST_APP_ID is unset (verification not configured). When
    # APP_ATTEST_REQUIRED is on, the bootstrap route turns a None service into a
    # 503 rather than minting an unattested identity.
    return getattr(request.app.state, "app_attest_service", None)


def get_auth_sessionmaker(request: Request):
    """Sessionmaker dedicated to the auth tables (None when auth is disabled)."""
    return getattr(request.app.state, "auth_sessionmaker", None)


def get_apple_verifier(request: Request) -> Optional[AppleIdentityVerifier]:
    # None until Sign in with Apple is configured; /auth/apple returns 503.
    return getattr(request.app.state, "apple_verifier", None)


def get_apple_oauth_client(request: Request) -> Optional[AppleOAuthClient]:
    return getattr(request.app.state, "apple_oauth_client", None)


def get_apple_token_cipher(request: Request) -> Optional[AppleTokenCipher]:
    return getattr(request.app.state, "apple_token_cipher", None)


def get_quiz_flow(request: Request) -> QuizFlowService:
    return request.app.state.quiz_flow


def get_question_store(request: Request) -> QuestionStore:
    return request.app.state.question_store


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
