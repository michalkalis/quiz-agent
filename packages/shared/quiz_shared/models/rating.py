"""Rating model for question feedback."""

from datetime import datetime
from typing import Optional
from pydantic import BaseModel, Field


class QuestionRating(BaseModel):
    """Individual question rating by user.

    Rating scale: 1-5
    - 1 = Thumbs down (poor question)
    - 5 = Thumbs up (great question)
    - 2-4 = Future granular ratings
    """

    # Identifiers
    id: str = Field(..., description="Unique rating ID (e.g., 'rating_xyz789')")
    question_id: str = Field(..., description="Question being rated")
    session_id: str = Field(..., description="Quiz session ID")
    user_id: Optional[str] = Field(None, description="User ID (optional for MVP)")

    # Rating data
    rating: int = Field(..., ge=1, le=5, description="Rating: 1-5 scale")
    feedback: Optional[str] = Field(None, description="Optional text feedback")

    # Context
    was_correct: bool = Field(..., description="Did user answer correctly?")
    user_answer: str = Field(..., description="What user answered")
    difficulty_at_time: str = Field(..., description="Difficulty when asked")

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
