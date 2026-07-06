"""Rating model for question feedback."""

import uuid
from datetime import datetime
from typing import Optional
from pydantic import BaseModel, Field


def _rating_id() -> str:
    return f"rating_{uuid.uuid4().hex}"


class QuestionRating(BaseModel):
    """Individual question rating by user.

    Rating scale: 1-5
    - 1 = Thumbs down (poor question)
    - 5 = Thumbs up (great question)
    - 2-4 = Future granular ratings

    Answer context (was_correct/user_answer/difficulty_at_time) is optional:
    the /rate endpoint fires after the answer flow and does not carry it
    (#41 A4 — requiring it made every SQL rating insert fail silently).
    """

    # Identifiers
    id: str = Field(
        default_factory=_rating_id,
        description="Unique rating ID (e.g., 'rating_xyz789')",
    )
    question_id: str = Field(..., description="Question being rated")
    session_id: Optional[str] = Field(None, description="Quiz session ID")
    user_id: Optional[str] = Field(None, description="User ID (optional for MVP)")

    # Rating data
    rating: int = Field(..., ge=1, le=5, description="Rating: 1-5 scale")
    feedback: Optional[str] = Field(None, description="Optional text feedback")

    # Context (optional — unknown at rating time in the current API)
    was_correct: Optional[bool] = Field(None, description="Did user answer correctly?")
    user_answer: Optional[str] = Field(None, description="What user answered")
    difficulty_at_time: Optional[str] = Field(None, description="Difficulty when asked")

    # Metadata
    created_at: datetime = Field(default_factory=datetime.now)

    class Config:
        json_schema_extra = {
            "example": {
                "id": "rating_xyz789",
                "question_id": "q_abc123",
                "session_id": "sess_456",
                "user_id": "user_1",
                "rating": 5,
                "feedback": "Great question!",
                "was_correct": True,
                "user_answer": "Paris",
                "difficulty_at_time": "easy",
                "created_at": "2025-12-11T10:00:00Z",
            }
        }
