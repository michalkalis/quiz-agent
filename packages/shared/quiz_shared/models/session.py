"""Session model for quiz state management."""

import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Union
from pydantic import BaseModel, Field

from .participant import Participant
from .phase import InvalidPhaseTransition, SessionPhase, is_valid_transition

logger = logging.getLogger(__name__)


class LastEvaluation(BaseModel):
    """The most recently graded submission, kept so a re-submit is idempotent (#133 1a).

    Clients re-POST an answer for a question the server has already graded: the
    transient-retry wrapper re-sends when a response is lost, and editing a voice
    transcript submits the corrected text after the original was accepted. With
    no record of what was graded, the retry was scored against the NEXT, unseen
    question and charged a second freemium question. Keeping the graded
    submission on the session lets the submit path recognise it by
    ``question_id`` and either replay the stored verdict or re-grade the new text
    against the SAME question — never advancing twice, never charging twice.

    The deltas are what the flow actually applied, so a re-grade reverses the
    previous effect exactly instead of recomputing it.
    """

    question_id: str = Field(..., description="Question this text was graded against")
    submitted_text: str = Field(
        ..., description="Raw submitted text (typed input or transcript), as received"
    )
    evaluation: Dict[str, Any] = Field(
        ..., description="The evaluation dict returned to the client; replayed verbatim"
    )
    feedback_received: List[str] = Field(
        default_factory=list,
        description="Parsed-intent strings that accompanied that submission",
    )
    points_awarded: float = Field(
        0.0, description="Score delta applied to the answering participant"
    )
    answered_count_delta: int = Field(
        0, description="answered_count delta applied (0 for a skip)"
    )
    participant_id: Optional[str] = Field(
        None,
        description=(
            "Participant the deltas were applied to (None = the single-player "
            "default, participants[0]); a reversal must target the same one"
        ),
    )
    translation: Optional[Dict[str, Any]] = Field(
        None,
        description=(
            "Serve-time translation record for that question. Kept because the "
            "session's current record has since been overwritten by the next "
            "question, and a re-grade must score against the exact strings the "
            "player saw."
        ),
    )
    regrade_count: int = Field(
        0,
        description=(
            "How many times this question has been re-graded with different text "
            "(#133 V6b). Re-grading is quota-free by design — editing a transcript "
            "must not cost a question — which left an unbounded paid path: each "
            "re-grade buys an evaluator LLM call (and, on voice, a Whisper "
            "transcription plus feedback TTS) at the route's 30/min. Legitimate "
            "editing is one or two corrections, so past REGRADE_CAP the flow "
            "replays the stored verdict instead of re-evaluating. Replays (same "
            "text) never touch this counter."
        ),
    )


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
        description="Participants in session (1 for single, N for multiplayer)",
    )

    # Configuration
    max_questions: int = Field(10, description="Total questions in quiz")
    current_difficulty: str = Field(
        "medium", description="Difficulty: easy | medium | hard"
    )
    category: Optional[str] = Field(
        None, description="Current category filter (e.g., 'music', 'movies', 'all')"
    )
    language: str = Field("en", description="Preferred language code (ISO 639-1)")
    include_images: bool = Field(
        False,
        description=(
            "Whether image-type questions may be served (#68). Default off — "
            "images are unsuitable while driving; user opts in per session."
        ),
    )
    preferred_topics: List[str] = Field(
        default_factory=list, description="Preferred topics: ['science', 'history']"
    )
    excluded_topics: List[str] = Field(
        default_factory=list, description="Excluded topics: ['sports', 'geography']"
    )
    disliked_topics: List[str] = Field(
        default_factory=list,
        description="Disliked topics (alias for excluded_topics): ['sports', 'geography']",
    )
    preferred_categories: List[str] = Field(
        default_factory=list, description="Preferred categories: ['music', 'movies']"
    )
    excluded_categories: List[str] = Field(
        default_factory=list, description="Excluded categories: ['children']"
    )
    pack_id: Optional[str] = Field(
        None,
        description=(
            "Custom quiz-pack id (#95). When set, the session plays ONLY that "
            "pack's questions (retriever scopes on questions.pack_id) and bypasses "
            "the free monthly quota — a pack is paid, curated content."
        ),
    )

    # Progress (single-player or aggregate)
    question_number: int = Field(0, description="Current question number (0-indexed)")
    score: float = Field(0.0, description="Running score (single-player only)")
    phase: SessionPhase = Field(
        SessionPhase.IDLE,
        description="Phase: idle | asking | awaiting_answer | finished",
    )

    # Question history
    asked_question_ids: List[str] = Field(
        default_factory=list, description="IDs of questions already asked this session"
    )
    client_excluded_ids: List[str] = Field(
        default_factory=list,
        description=(
            "Client-supplied cross-session history (from /start's "
            "excluded_question_ids), excluded from retrieval for every "
            "question in the session — not just the first"
        ),
    )
    skipped_question_numbers: List[int] = Field(
        default_factory=list, description="Question numbers that were skipped"
    )

    # Current question
    current_question_id: Optional[str] = Field(None, description="Current question ID")
    current_question_text: Optional[str] = Field(
        None, description="Current question text"
    )
    # #132 D — the ONE translated payload the player actually saw. Written once
    # at serve time (one LLM call per question), then read by evaluation, the
    # result screen and the audio path so all three agree on the same strings.
    # Internal state, never projected into a response: it carries the answer.
    current_question_translation: Optional[Dict[str, Any]] = Field(
        None,
        description=(
            "Serve-time translation of the current question (stem, options, "
            "explanation, answer) in the session language. None for English "
            "sessions and when translation fell back to English."
        ),
    )
    current_answer: Optional[str] = Field(None, description="Current correct answer")
    current_topic: Optional[str] = Field(None, description="Current question topic")
    last_user_answer: Optional[str] = Field(None, description="Last answer provided")
    last_result: Optional[str] = Field(
        None,
        description="Last result: correct | partially_correct | incorrect | skipped",
    )

    # #133 1a — the last graded submission, so a client that re-sends the same
    # question_id gets its verdict replayed (or the edited text re-graded against
    # that same question) instead of grading it against the current question.
    last_evaluation: Optional[LastEvaluation] = Field(
        None, description="Last graded submission; makes a re-submit idempotent"
    )

    # Timestamps
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    updated_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    expires_at: datetime = Field(
        default_factory=lambda: datetime.now(timezone.utc) + timedelta(minutes=30),
        description="Session expiry (30 min TTL)",
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

    def transition(
        self, to: Union[SessionPhase, str], *, caller: Optional[str] = None
    ) -> None:
        """Move the session to a new phase, validating against the transition table.

        Raises `InvalidPhaseTransition` if the table forbids `current -> to`.
        Self-transitions are forbidden — if the caller is asking for the same
        phase, that's a logic bug at the call site (Issue 19 family).
        """
        target = SessionPhase(to) if not isinstance(to, SessionPhase) else to
        current = (
            self.phase
            if isinstance(self.phase, SessionPhase)
            else SessionPhase(self.phase)
        )

        if not is_valid_transition(current, target):
            logger.warning(
                "Invalid phase transition rejected: %s -> %s (caller=%s, session=%s)",
                current.value,
                target.value,
                caller or "?",
                self.session_id,
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
