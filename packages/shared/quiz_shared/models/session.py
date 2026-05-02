"""Session model for quiz state management."""

import logging
from datetime import datetime, timedelta, timezone
from typing import List, Optional, Union
from pydantic import BaseModel, Field

from .participant import Participant
from .phase import InvalidPhaseTransition, SessionPhase, is_valid_transition

logger = logging.getLogger(__name__)


class QuizSession(BaseModel):
    """Quiz session state.

    Supports both single-player and multiplayer modes.
    Tracks quiz progress, participants, and question history.
    """

    # Identifiers
    session_id: str = Field(..., description="Unique session ID")
    user_id: Optional[str] = Field(None, description="User ID (for single-player)")

    # Multiplayer support (future)
    mode: str = Field("single", description="Mode: single | multiplayer")
    room_code: Optional[str] = Field(None, description="Room code for multiplayer")
    participants: List[Participant] = Field(
        default_factory=list,
        description="Participants in session (1 for single, N for multiplayer)"
    )

    # Configuration
    max_questions: int = Field(10, description="Total questions in quiz")
    current_difficulty: str = Field(
        "medium",
        description="Difficulty: easy | medium | hard"
    )
    category: Optional[str] = Field(
        None,
        description="Current category filter (e.g., 'music', 'movies', 'all')"
    )
    language: str = Field("en", description="Preferred language code (ISO 639-1)")
    preferred_topics: List[str] = Field(
        default_factory=list,
        description="Preferred topics: ['science', 'history']"
    )
    excluded_topics: List[str] = Field(
        default_factory=list,
        description="Excluded topics: ['sports', 'geography']"
    )
    disliked_topics: List[str] = Field(
        default_factory=list,
        description="Disliked topics (alias for excluded_topics): ['sports', 'geography']"
    )
    preferred_categories: List[str] = Field(
        default_factory=list,
        description="Preferred categories: ['music', 'movies']"
    )
    excluded_categories: List[str] = Field(
        default_factory=list,
        description="Excluded categories: ['children']"
    )

    # Progress (single-player or aggregate)
    question_number: int = Field(0, description="Current question number (0-indexed)")
    score: float = Field(0.0, description="Running score (single-player only)")
    phase: SessionPhase = Field(
        SessionPhase.IDLE,
        description="Phase: idle | asking | awaiting_answer | finished"
    )

    # Question history
    asked_question_ids: List[str] = Field(
        default_factory=list,
        description="IDs of questions already asked this session"
    )
    skipped_question_numbers: List[int] = Field(
        default_factory=list,
        description="Question numbers that were skipped"
    )

    # Current question
    current_question_id: Optional[str] = Field(None, description="Current question ID")
    current_question_text: Optional[str] = Field(None, description="Current question text")
    current_answer: Optional[str] = Field(None, description="Current correct answer")
    current_topic: Optional[str] = Field(None, description="Current question topic")
    last_user_answer: Optional[str] = Field(None, description="Last answer provided")
    last_result: Optional[str] = Field(
        None,
        description="Last result: correct | partially_correct | incorrect | skipped"
    )

    # Timestamps
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    updated_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    expires_at: datetime = Field(
        default_factory=lambda: datetime.now(timezone.utc) + timedelta(minutes=30),
        description="Session expiry (30 min TTL)"
    )

    def get_participant(self, participant_id: str) -> Optional[Participant]:
        """Get participant by ID."""
        for p in self.participants:
            if p.participant_id == participant_id:
                return p
        return None

    def is_multiplayer(self) -> bool:
        """Check if session is multiplayer."""
        return self.mode == "multiplayer" or len(self.participants) > 1

    def transition(self, to: Union[SessionPhase, str], *, caller: Optional[str] = None) -> None:
        """Move the session to a new phase, validating against the transition table.

        Raises `InvalidPhaseTransition` if the table forbids `current -> to`.
        Self-transitions are forbidden — if the caller is asking for the same
        phase, that's a logic bug at the call site (Issue 19 family).
        """
        target = SessionPhase(to) if not isinstance(to, SessionPhase) else to
        current = self.phase if isinstance(self.phase, SessionPhase) else SessionPhase(self.phase)

        if not is_valid_transition(current, target):
            logger.warning(
                "Invalid phase transition rejected: %s -> %s (caller=%s, session=%s)",
                current.value, target.value, caller or "?", self.session_id,
            )
            raise InvalidPhaseTransition(current, target)

        self.phase = target

    class Config:
        json_schema_extra = {
            "example": {
                "session_id": "sess_abc123",
                "user_id": None,
                "mode": "single",
                "room_code": None,
                "participants": [],
                "max_questions": 10,
                "current_difficulty": "medium",
                "language": "sk",
                "preferred_topics": ["science"],
                "excluded_topics": ["sports"],
                "preferred_categories": ["music"],
                "excluded_categories": ["children"],
                "question_number": 2,
                "score": 1.5,
                "phase": "awaiting_answer",
                "asked_question_ids": ["q_abc123", "q_def456"],
                "skipped_question_numbers": [],
                "current_question_id": "q_def456",
            }
        }
