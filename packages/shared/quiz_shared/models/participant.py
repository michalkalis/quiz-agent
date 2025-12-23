"""Participant model for multiplayer quiz sessions."""

from datetime import datetime, timezone
from typing import Optional
from pydantic import BaseModel, Field


class Participant(BaseModel):
    """Individual participant in a quiz session.

    Supports both single-player and multiplayer modes.
    """

    # Identity
    participant_id: str = Field(..., description="Unique participant ID")
    user_id: Optional[str] = Field(None, description="User ID if authenticated")
    display_name: str = Field(..., description="Display name in quiz")

    # Progress
    score: float = Field(0.0, description="Participant's score")
    answered_count: int = Field(0, description="Questions answered (not skipped)")
    correct_count: int = Field(0, description="Correct answers")

    # Current state
    last_answer: Optional[str] = Field(None, description="Last answer submitted")
    last_result: Optional[str] = Field(
        None,
        description="Last result: correct | partially_correct | incorrect | skipped"
    )
    is_ready: bool = Field(True, description="Ready for next question")

    # Multiplayer
    is_host: bool = Field(False, description="Host controls quiz flow")
    joined_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))

    class Config:
        json_schema_extra = {
            "example": {
                "participant_id": "p_abc123",
                "user_id": "user_456",
                "display_name": "Alice",
                "score": 7.5,
                "answered_count": 9,
                "correct_count": 6,
                "is_host": True,
                "is_ready": True
            }
        }
