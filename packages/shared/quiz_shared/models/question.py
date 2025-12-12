"""Question model with support for multiple question types."""

from datetime import datetime
from typing import Dict, List, Optional, Union
from pydantic import BaseModel, Field


class Question(BaseModel):
    """Question stored in ChromaDB with semantic embeddings.

    Supports multiple question types: text, text_multichoice, audio, image, video
    """

    # Identifiers
    id: str = Field(..., description="Unique question ID (e.g., 'q_abc123')")

    # Question content
    question: str = Field(..., description="The question text")
    type: str = Field(
        "text",
        description="Question type: text | text_multichoice | audio | image | video"
    )

    # Answers (flexible for multiple choice or text)
    possible_answers: Optional[Dict[str, str]] = Field(
        None,
        description="For multiple choice: {'a': 'Paris', 'b': 'London', ...}"
    )
    correct_answer: Union[str, List[str]] = Field(
        ...,
        description="Correct answer: 'Paris' or identifier 'a' or ['a', 'c'] for multi-select"
    )

    # Alternative acceptable answers (for text questions)
    alternative_answers: List[str] = Field(
        default_factory=list,
        description="Alternative acceptable answers: ['paris', 'paris france']"
    )

    # Classification
    topic: str = Field(..., description="Topic: Geography, History, Science, etc.")
    category: str = Field(
        ...,
        description="Category: adults, children, harry-potter, music, general, etc."
    )
    difficulty: str = Field(..., description="Difficulty: easy | medium | hard")
    tags: List[str] = Field(
        default_factory=list,
        description="Additional tags: ['europe', 'capitals', 'france']"
    )

    # Metadata
    created_at: datetime = Field(default_factory=datetime.now)
    created_by: Optional[str] = Field(None, description="Admin user ID")
    source: str = Field(
        "generated",
        description="Source: generated | manual | imported"
    )

    # Quality metrics
    usage_count: int = Field(0, description="Times used in quizzes")
    user_ratings: Dict[str, int] = Field(
        default_factory=dict,
        description="User ratings: {'user_1': 5, 'user_2': 4} (1-5 scale)"
    )

    # Media (for audio/image/video types - future)
    media_url: Optional[str] = Field(None, description="URL to audio/image/video file")
    media_duration_seconds: Optional[int] = Field(
        None,
        description="Duration for audio/video"
    )

    # Explanation
    explanation: Optional[str] = Field(
        None,
        description="Optional educational context or explanation"
    )

    def calculate_avg_rating(self) -> float:
        """Calculate average rating from user_ratings dict."""
        if not self.user_ratings:
            return 0.0
        return sum(self.user_ratings.values()) / len(self.user_ratings)

    class Config:
        json_schema_extra = {
            "example": {
                "id": "q_abc123",
                "question": "What is the capital of France?",
                "type": "text",
                "possible_answers": None,
                "correct_answer": "Paris",
                "alternative_answers": ["paris", "paris france"],
                "topic": "Geography",
                "category": "adults",
                "difficulty": "easy",
                "tags": ["europe", "capitals", "france"],
                "created_at": "2025-12-11T10:00:00Z",
                "source": "generated",
                "usage_count": 0,
                "user_ratings": {"user_1": 5, "user_2": 4},
            }
        }
