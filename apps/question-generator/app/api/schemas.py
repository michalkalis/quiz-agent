"""Pydantic schemas for API requests/responses."""

from typing import List, Optional, Dict, Any
from pydantic import BaseModel, Field


class GenerateRequest(BaseModel):
    """Request to generate questions."""
    count: int = Field(10, ge=1, le=50, description="Number of questions (1-50)")
    difficulty: str = Field("medium", description="easy, medium, or hard")
    topics: Optional[List[str]] = Field(None, description="Preferred topics")
    categories: Optional[List[str]] = Field(None, description="Categories (adults, children, etc.)")
    type: str = Field("text", description="text or text_multichoice")
    excluded_topics: Optional[List[str]] = Field(None, description="Topics to avoid")


class ImportRequest(BaseModel):
    """Request to import questions from JSON."""
    questions: List[Dict[str, Any]] = Field(..., description="List of question dicts")
    source: str = Field("chatgpt", description="Source of questions")


class ApproveRequest(BaseModel):
    """Request to approve questions."""
    question_ids: List[str] = Field(..., description="Question IDs to approve")
    edits: Optional[Dict[str, Dict[str, Any]]] = Field(None, description="Optional edits before approval")
    force: bool = Field(False, description="Force approval even if duplicates found")


class QuestionResponse(BaseModel):
    """Response with question data."""
    id: str
    question: str
    type: str
    correct_answer: str
    topic: str
    category: str
    difficulty: str
    possible_answers: Optional[Dict[str, str]] = None
    alternative_answers: List[str] = []
    tags: List[str] = []
    quality_score: Optional[float] = None


class GenerateResponse(BaseModel):
    """Response from generate endpoint."""
    questions: List[QuestionResponse]
    generation_time_seconds: float


class ImportResponse(BaseModel):
    """Response from import endpoint."""
    imported_count: int
    pending_review: List[str]


class ApproveResponse(BaseModel):
    """Response from approve endpoint."""
    approved_count: int
    question_ids: List[str]
    failed: Optional[List[Dict[str, str]]] = None


class SearchResponse(BaseModel):
    """Response from search endpoint."""
    questions: List[QuestionResponse]
    total: int


class DuplicateInfo(BaseModel):
    """Information about a potential duplicate."""
    question: QuestionResponse
    similarity: float


class DuplicatesResponse(BaseModel):
    """Response from duplicates check."""
    duplicates: List[DuplicateInfo]
    is_duplicate: bool


# Advanced Generation Schemas

class AdvancedGenerateRequest(BaseModel):
    """Request to generate questions using advanced pipeline."""
    count: int = Field(10, ge=1, le=50, description="Number of questions to return (1-50)")
    difficulty: str = Field("medium", description="easy, medium, or hard")
    topics: Optional[List[str]] = Field(None, description="Preferred topics")
    categories: Optional[List[str]] = Field(None, description="Categories (adults, children, etc.)")
    type: str = Field("text", description="text or text_multichoice")
    excluded_topics: Optional[List[str]] = Field(None, description="Topics to avoid")
    enable_best_of_n: bool = Field(True, description="Use Best-of-N selection")
    n_multiplier: int = Field(3, ge=1, le=5, description="Generate this many times count")
    min_quality_score: float = Field(7.0, ge=0.0, le=10.0, description="Minimum quality score")


class AdvancedQuestionResponse(QuestionResponse):
    """Response with question data including quality metadata."""
    review_status: str
    quality_ratings: Optional[Dict[str, int]] = None
    generation_metadata: Optional[Dict[str, Any]] = None


class AdvancedGenerateResponse(BaseModel):
    """Response from advanced generate endpoint."""
    questions: List[AdvancedQuestionResponse]
    generation_time_seconds: float
    stats: Dict[str, Any] = Field(
        ...,
        description="Generation statistics: generated_count, selected_count, avg_score, etc."
    )


# Review Workflow Schemas

class ReviewRequest(BaseModel):
    """Request to review (approve/reject) a question."""
    question_id: str
    status: str = Field(..., description="approved | rejected | needs_revision")
    quality_ratings: Dict[str, int] = Field(
        ...,
        description="Ratings: surprise_factor, clarity, universal_appeal, creativity (1-5)"
    )
    review_notes: Optional[str] = Field(None, description="Reviewer feedback")
    reviewer_id: str = Field("admin", description="Reviewer user ID")


class ReviewResponse(BaseModel):
    """Response from review endpoint."""
    question_id: str
    status: str
    message: str


class PendingReviewResponse(BaseModel):
    """Response from list pending reviews endpoint."""
    questions: List[AdvancedQuestionResponse]
    total: int


class ReviewStats(BaseModel):
    """Statistics about review workflow."""
    pending_review: int
    approved: int
    rejected: int
    needs_revision: int
    avg_quality_score: Optional[float] = None
