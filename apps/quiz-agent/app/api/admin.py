"""Admin API endpoints for question management.

Secured endpoints for importing and managing questions.
Requires ADMIN_API_KEY for authentication.
"""

import logging
from fastapi import APIRouter, Depends, HTTPException, Header, Request, status
from pydantic import BaseModel, Field
from typing import List, Optional, Dict, Any
from datetime import datetime
import os

logger = logging.getLogger(__name__)

from quiz_shared.models.question import Question
from quiz_shared.database.chroma_client import ChromaDBClient
from ..rate_limit import limiter


from .deps import get_chroma_client

router = APIRouter(prefix="/api/v1/admin", tags=["Admin"])


def verify_admin_key(x_admin_key: str = Header(..., description="Admin API key for authentication")):
    """Verify admin API key from header.

    Args:
        x_admin_key: Admin API key from X-Admin-Key header

    Raises:
        HTTPException: If key is missing or invalid
    """
    admin_key = os.getenv("ADMIN_API_KEY")

    if not admin_key:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Admin API key not configured on server. Set ADMIN_API_KEY environment variable."
        )

    if x_admin_key != admin_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid admin API key"
        )


# Pydantic models for request/response
class QuestionImport(BaseModel):
    """Question data for import."""
    id: str
    question: str
    type: str = "text"
    correct_answer: str | List[str]
    alternative_answers: Optional[List[str]] = []
    possible_answers: Optional[List[str]] = None
    topic: str = "General"
    category: str = "general"
    difficulty: str = "medium"
    tags: List[str] = []
    source: str = "import"
    created_by: Optional[str] = None
    media_url: Optional[str] = None
    media_duration_seconds: Optional[int] = None
    explanation: Optional[str] = None
    image_subtype: Optional[str] = None
    language_dependent: bool = False
    generation_metadata: Optional[Dict[str, Any]] = None


class ImportQuestionsRequest(BaseModel):
    """Request to import questions."""
    questions: List[QuestionImport] = Field(..., description="List of questions to import")
    skip_duplicates: bool = Field(True, description="Skip questions that already exist (by ID)")
    force: bool = Field(False, description="Force import even if duplicates detected (by similarity)")


class ImportQuestionsResponse(BaseModel):
    """Response from question import."""
    success: bool
    imported_count: int
    skipped_count: int
    failed_count: int
    skipped_ids: List[str] = []
    failed_ids: List[str] = []
    message: str


class QuestionStats(BaseModel):
    """Statistics about questions in database."""
    total_questions: int
    by_difficulty: Dict[str, int]
    by_topic: Dict[str, int]
    by_category: Dict[str, int]


@router.post("/questions/import", response_model=ImportQuestionsResponse)
@limiter.limit("5/minute")
async def import_questions(
    request: Request,
    import_request: ImportQuestionsRequest,
    chroma_client: ChromaDBClient = Depends(get_chroma_client),
    _: str = Depends(verify_admin_key),
):

    imported = 0
    skipped = 0
    failed = 0
    skipped_ids = []
    failed_ids = []

    for q_data in import_request.questions:
        try:
            # Check if question already exists (by ID)
            if import_request.skip_duplicates:
                existing = chroma_client.get_question(q_data.id)
                if existing:
                    skipped += 1
                    skipped_ids.append(q_data.id)
                    continue

            # Convert to Question object
            question = Question(
                id=q_data.id,
                question=q_data.question,
                type=q_data.type,
                correct_answer=q_data.correct_answer,
                alternative_answers=q_data.alternative_answers,
                possible_answers=q_data.possible_answers,
                topic=q_data.topic,
                category=q_data.category,
                difficulty=q_data.difficulty,
                tags=q_data.tags,
                created_at=datetime.now(),
                source=q_data.source,
                created_by=q_data.created_by,
                media_url=q_data.media_url,
                media_duration_seconds=q_data.media_duration_seconds,
                explanation=q_data.explanation,
                image_subtype=q_data.image_subtype,
                language_dependent=q_data.language_dependent,
                generation_metadata=q_data.generation_metadata,
                usage_count=0,
                user_ratings={},
                review_status="approved"  # Auto-approve imports
            )

            # Check for semantic duplicates unless forced
            if not import_request.force:
                duplicates = chroma_client.find_duplicates(question.question, threshold=0.85)
                if duplicates:
                    # Question text is very similar to existing question
                    skipped += 1
                    skipped_ids.append(q_data.id)
                    logger.info("Skipped %s: Similar to %s", q_data.id, duplicates[0][0].id)
                    continue

            # Add to database
            success = chroma_client.add_question(question)

            if success:
                imported += 1
            else:
                failed += 1
                failed_ids.append(q_data.id)

        except Exception as e:
            logger.error("Error importing question %s: %s", q_data.id, e)
            failed += 1
            failed_ids.append(q_data.id)

    return ImportQuestionsResponse(
        success=True,
        imported_count=imported,
        skipped_count=skipped,
        failed_count=failed,
        skipped_ids=skipped_ids,
        failed_ids=failed_ids,
        message=f"Imported {imported} questions, skipped {skipped}, failed {failed}"
    )


@router.get("/questions")
@limiter.limit("5/minute")
async def list_questions(
    request: Request,
    chroma_client: ChromaDBClient = Depends(get_chroma_client),
    _: str = Depends(verify_admin_key),
    search: Optional[str] = None,
    topic: Optional[str] = None,
    limit: int = 1000,
):

    all_questions = chroma_client.get_all_questions(limit=limit)

    results = []
    for q in all_questions:
        if search and search.lower() not in q.question.lower():
            continue
        if topic and q.topic.lower() != topic.lower():
            continue
        results.append({
            "id": q.id,
            "question": q.question,
            "correct_answer": q.correct_answer,
            "topic": q.topic,
            "difficulty": q.difficulty,
            "type": q.type,
        })

    return {"total": len(results), "questions": results}


@router.get("/questions/stats", response_model=QuestionStats)
@limiter.limit("5/minute")
async def get_question_stats(
    request: Request,
    chroma_client: ChromaDBClient = Depends(get_chroma_client),
    _: str = Depends(verify_admin_key),
):

    # Get all questions
    all_questions = chroma_client.get_all_questions(limit=10000)

    # Calculate statistics
    by_difficulty = {}
    by_topic = {}
    by_category = {}

    for q in all_questions:
        # Count by difficulty
        by_difficulty[q.difficulty] = by_difficulty.get(q.difficulty, 0) + 1

        # Count by topic
        by_topic[q.topic] = by_topic.get(q.topic, 0) + 1

        # Count by category
        by_category[q.category] = by_category.get(q.category, 0) + 1

    return QuestionStats(
        total_questions=len(all_questions),
        by_difficulty=by_difficulty,
        by_topic=by_topic,
        by_category=by_category
    )


@router.delete("/questions/{question_id}")
@limiter.limit("5/minute")
async def delete_question(
    request: Request,
    question_id: str,
    chroma_client: ChromaDBClient = Depends(get_chroma_client),
    _: str = Depends(verify_admin_key),
):

    # Check if question exists
    question = chroma_client.get_question(question_id)
    if not question:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Question {question_id} not found"
        )

    # Delete question
    success = chroma_client.delete_question(question_id)

    if not success:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to delete question"
        )

    return {"success": True, "message": f"Deleted question {question_id}"}
