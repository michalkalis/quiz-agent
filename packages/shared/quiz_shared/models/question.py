"""Question model with support for multiple question types."""

from datetime import datetime
from typing import Dict, List, Optional, Union, Any
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

    # Review workflow
    review_status: str = Field(
        "pending_review",
        description="Status: pending_review | approved | rejected | needs_revision"
    )
    reviewed_by: Optional[str] = Field(
        None,
        description="Reviewer user ID"
    )
    reviewed_at: Optional[datetime] = Field(
        None,
        description="When reviewed"
    )
    review_notes: Optional[str] = Field(
        None,
        description="Reviewer feedback and notes"
    )

    # Detailed quality ratings (used during review)
    quality_ratings: Optional[Dict[str, int]] = Field(
        None,
        description="Detailed ratings: {'surprise_factor': 4, 'clarity': 5, 'universal_appeal': 4, 'creativity': 5} (1-5 scale)"
    )

    # Generation metadata (for AI-generated questions)
    generation_metadata: Optional[Dict[str, Any]] = Field(
        None,
        description="AI generation details: {'model': 'gpt-4o', 'temperature': 0.8, 'prompt_version': 'v2', 'stage': 'regenerate', 'ai_score': 8.5, 'ai_reasoning': '...'}"
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

    def calculate_quality_score(self) -> float:
        """Calculate overall quality score from detailed quality_ratings (1-5 scale)."""
        if not self.quality_ratings:
            return 0.0
        return sum(self.quality_ratings.values()) / len(self.quality_ratings)

    def is_approved(self) -> bool:
        """Check if question is approved for use in quizzes."""
        return self.review_status == "approved"

    def needs_review(self) -> bool:
        """Check if question needs human review."""
        return self.review_status in ["pending_review", "needs_revision"]

    def get_ai_score(self) -> Optional[float]:
        """Get AI-generated quality score if available."""
        if self.generation_metadata and "ai_score" in self.generation_metadata:
            return self.generation_metadata["ai_score"]
        return None

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
