"""Question model with support for multiple question types."""

import uuid
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
    language_dependent: bool = Field(
        False,
        description="True if question relies on English language properties (wordplay, spelling, letter counts, acronyms)"
    )

    # Metadata
    created_at: datetime = Field(default_factory=datetime.now)
    created_by: Optional[str] = Field(None, description="Admin user ID")
    source: str = Field(
        "generated",
        description="Source: generated | manual | imported"
    )
    source_url: Optional[str] = Field(
        None,
        description="URL to source article or reference"
    )
    source_excerpt: Optional[str] = Field(
        None,
        description="Brief excerpt from source (1-2 sentences max)"
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

    # Media (for audio/image/video types)
    media_url: Optional[str] = Field(None, description="URL to audio/image/video file")
    image_subtype: Optional[str] = Field(
        None,
        description="Image question subtype: silhouette | blind_map | hint_image"
    )
    media_duration_seconds: Optional[int] = Field(
        None,
        description="Duration for audio/video"
    )

    # Explanation
    explanation: Optional[str] = Field(
        None,
        description="Optional educational context or explanation"
    )

    # Embedding cache (for performance optimization)
    embedding: Optional[List[float]] = Field(
        None,
        description="Cached embedding vector (1536-dim for text-embedding-3-small)"
    )

    # Time-sensitive question support
    expires_at: Optional[datetime] = None
    freshness_tag: Optional[str] = None  # e.g., "2024-news", "trending-feb-2024"

    def is_expired(self) -> bool:
        """Check if this question has expired."""
        if self.expires_at is None:
            return False
        from datetime import timezone
        now = datetime.now(timezone.utc)
        expires = self.expires_at
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=timezone.utc)
        return now > expires

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

    @classmethod
    def from_dict(
        cls,
        data: Dict[str, Any],
        source: str = "generated",
        default_difficulty: str = "medium",
        default_category: str = "general",
    ) -> "Question":
        """Create a Question from a dict (e.g. LLM output or JSON import).

        Handles:
        - Basic fields with sensible defaults
        - V2 CoT metadata (reasoning, self_critique, quality_ratings)
        - Flattened self_critique (GPT-4o sometimes puts dimensions at top level)

        Args:
            data: Question data dict
            source: Source identifier (generated, imported, manual)
            default_difficulty: Fallback difficulty
            default_category: Fallback category
        """
        question_id = data.get("id", f"temp_{uuid.uuid4().hex[:8]}")

        # Extract V2 CoT fields
        reasoning = data.get("reasoning", {})
        self_critique = data.get("self_critique", {})

        # Handle flattened self_critique (GPT-4o edge case)
        if not self_critique and "surprise_factor" in data:
            self_critique = {
                k: data[k]
                for k in (
                    "surprise_factor", "universal_appeal", "clever_framing",
                    "educational_value", "answerability", "overall_score",
                )
                if k in data
            }
            if "self_critique_reasoning" in data:
                self_critique["reasoning"] = data["self_critique_reasoning"]

        # Build generation metadata
        generation_metadata: Optional[Dict[str, Any]] = None
        quality_ratings: Optional[Dict[str, int]] = None

        if reasoning or self_critique:
            generation_metadata = {}
            if reasoning:
                generation_metadata["reasoning"] = reasoning
            if self_critique:
                generation_metadata["self_critique"] = self_critique
                generation_metadata["ai_score"] = self_critique.get("overall_score", 0)
                generation_metadata["ai_reasoning"] = self_critique.get("reasoning", "")
                quality_ratings = {
                    "surprise_factor": self_critique.get("surprise_factor", 0),
                    "universal_appeal": self_critique.get("universal_appeal", 0),
                    "clever_framing": self_critique.get("clever_framing", 0),
                    "educational_value": self_critique.get("educational_value", 0),
                    "answerability": self_critique.get("answerability", 0),
                }

        # Use explicitly provided generation_metadata/quality_ratings if present
        if "generation_metadata" in data and data["generation_metadata"]:
            generation_metadata = data["generation_metadata"]
        if "quality_ratings" in data and data["quality_ratings"]:
            quality_ratings = data["quality_ratings"]

        return cls(
            id=question_id,
            question=data.get("question", ""),
            type=data.get("type", "text"),
            possible_answers=data.get("possible_answers"),
            correct_answer=data.get("correct_answer", ""),
            alternative_answers=data.get("alternative_answers", []),
            topic=data.get("topic", "General"),
            category=data.get("category", default_category),
            difficulty=data.get("difficulty", default_difficulty),
            tags=data.get("tags", []),
            language_dependent=data.get("language_dependent", False),
            media_url=data.get("media_url"),
            image_subtype=data.get("image_subtype"),
            explanation=data.get("explanation"),
            source=data.get("source", source),
            source_url=data.get("source_url"),
            source_excerpt=data.get("source_excerpt"),
            review_status=data.get("review_status", "pending_review"),
            quality_ratings=quality_ratings,
            generation_metadata=generation_metadata,
        )

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
