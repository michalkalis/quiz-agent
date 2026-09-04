"""Admin API endpoints for question management.

Secured endpoints for importing and managing questions.
Requires ADMIN_API_KEY for authentication.
"""

import logging
from fastapi import APIRouter, Depends, HTTPException, Header, Request, status
from pydantic import BaseModel, Field
from typing import List, Literal, Optional, Dict, Any
from datetime import datetime
import hmac
import os

logger = logging.getLogger(__name__)

from quiz_shared.models.question import Question
from quiz_shared.database.question_store import QuestionStore
from ..rate_limit import limiter


from .deps import get_question_store

router = APIRouter(prefix="/api/v1/admin", tags=["Admin"])


def verify_admin_key(
    x_admin_key: str = Header(..., description="Admin API key for authentication"),
):
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
            detail="Admin API key not configured on server. Set ADMIN_API_KEY environment variable.",
        )

    # Compare as bytes: compare_digest raises TypeError on non-ASCII str (a
    # client header is latin-1-decoded, so an attacker could trigger a 500).
    if not hmac.compare_digest(x_admin_key.encode(), admin_key.encode()):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid admin API key"
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
    review_status: Literal["pending_review", "approved"] = Field(
        "pending_review",
        description=(
            "Review status stamped on the imported row. Defaults to "
            "'pending_review' (machine gates only, TestFlight-only serving); "
            "pass 'approved' only when a human has actually reviewed the "
            "question (founder rule, see CONTEXT.md)."
        ),
    )


class ImportQuestionsRequest(BaseModel):
    """Request to import questions."""

    questions: List[QuestionImport] = Field(
        ..., description="List of questions to import"
    )
    skip_duplicates: bool = Field(
        True, description="Skip questions that already exist (by ID)"
    )
    force: bool = Field(
        False, description="Force import even if duplicates detected (by similarity)"
    )


class ImportQuestionsResponse(BaseModel):
    """Response from question import."""

    success: bool
    imported_count: int
    skipped_count: int
    failed_count: int
    skipped_ids: List[str] = []
    failed_ids: List[str] = []
    message: str


class SourceBackfillItem(BaseModel):
    """Single source attribution update for a question."""

    id: str
    source_url: Optional[str] = None
    source_excerpt: Optional[str] = None


class BackfillSourcesRequest(BaseModel):
    """Request to backfill source_url / source_excerpt on existing questions."""

    items: List[SourceBackfillItem]


class BackfillSourcesResponse(BaseModel):
    """Response from source backfill."""

    success: bool
    updated_count: int
    not_found_count: int
    skipped_count: int
    not_found_ids: List[str] = []


class ReviewStatusUpdateRequest(BaseModel):
    """Request to retire questions from serving (or bring them back)."""

    ids: List[str] = Field(..., min_length=1, description="Question IDs to update")
    # Only the two serving-relevant statuses are settable here. The voice read
    # path filters `review_status == "approved"`, so "archived" takes a question
    # out of play without deleting it (and back again); the generation-review
    # statuses stay owned by the review flow.
    status: Literal["archived", "approved"] = Field(
        ..., description="New review status: archived (retire) or approved (restore)"
    )


class ReviewStatusUpdateResponse(BaseModel):
    """Response from a review-status update."""

    success: bool
    updated_count: int
    unchanged_count: int
    not_found_count: int
    not_found_ids: List[str] = []


#: Canonical interest-based category taxonomy (2026-08 revamp). The iOS picker
#: (`Config.categoryOptions`) mirrors this list; pack questions keep free-form
#: categories and are reached via pack selection, not this filter.
CATEGORY_TAXONOMY = (
    "science-nature",
    "history",
    "geography-world",
    "movies-music",
    "sports",
    "food-everyday",
)


class CategoryAssignment(BaseModel):
    """One question-id → category assignment."""

    id: str
    category: Literal[
        "science-nature",
        "history",
        "geography-world",
        "movies-music",
        "sports",
        "food-everyday",
    ]


class SetCategoryRequest(BaseModel):
    """Request to re-categorize existing questions."""

    assignments: List[CategoryAssignment] = Field(..., min_length=1)


class SetCategoryResponse(BaseModel):
    """Response from a category update."""

    success: bool
    updated_count: int
    unchanged_count: int
    not_found_count: int
    not_found_ids: List[str] = []


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
    store: QuestionStore = Depends(get_question_store),
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
                existing = store.get(q_data.id)
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
                review_status=q_data.review_status,
            )

            # Check for semantic duplicates unless forced
            if not import_request.force:
                duplicates = store.find_duplicates(question.question, threshold=0.85)
                if duplicates:
                    # Question text is very similar to existing question
                    skipped += 1
                    skipped_ids.append(q_data.id)
                    logger.info(
                        "Skipped %s: Similar to %s", q_data.id, duplicates[0][0].id
                    )
                    continue

            # Add to database
            success = store.add(question)

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
        message=f"Imported {imported} questions, skipped {skipped}, failed {failed}",
    )


@router.post("/questions/backfill-sources", response_model=BackfillSourcesResponse)
@limiter.limit("5/minute")
async def backfill_sources(
    request: Request,
    payload: BackfillSourcesRequest,
    store: QuestionStore = Depends(get_question_store),
    _: str = Depends(verify_admin_key),
):
    """Backfill source_url / source_excerpt on existing questions.

    Goes through `store.get` + `store.upsert` so metadata serialization stays
    in one place. The existing embedding on the fetched Question is reused by
    the store, so we don't pay for re-embedding when only attribution changes.
    """
    updated = 0
    skipped = 0
    not_found_ids: List[str] = []

    for item in payload.items:
        if item.source_url is None and item.source_excerpt is None:
            skipped += 1
            continue
        question = store.get(item.id)
        if question is None:
            not_found_ids.append(item.id)
            continue
        changed = False
        if item.source_url is not None and question.source_url != item.source_url:
            question.source_url = item.source_url
            changed = True
        if (
            item.source_excerpt is not None
            and question.source_excerpt != item.source_excerpt
        ):
            question.source_excerpt = item.source_excerpt
            changed = True
        if not changed:
            skipped += 1
            continue

        if store.upsert(question):
            updated += 1
        else:
            not_found_ids.append(item.id)

    return BackfillSourcesResponse(
        success=True,
        updated_count=updated,
        not_found_count=len(not_found_ids),
        skipped_count=skipped,
        not_found_ids=not_found_ids,
    )


@router.post("/questions/review-status", response_model=ReviewStatusUpdateResponse)
@limiter.limit("5/minute")
async def set_review_status(
    request: Request,
    payload: ReviewStatusUpdateRequest,
    store: QuestionStore = Depends(get_question_store),
    _: str = Depends(verify_admin_key),
):
    """Archive existing questions (or restore archived ones) by ID.

    Corpus curation: retiring a weak batch must not destroy it, so this flips
    `review_status` instead of deleting — the read path serves only `approved`,
    and the same call with `status="approved"` puts a batch back.

    Goes through `store.get` + `store.upsert` like the source backfill, so the
    fetched Question's embedding is reused and a status flip never re-embeds.
    """
    updated = 0
    unchanged = 0
    not_found_ids: List[str] = []

    for question_id in payload.ids:
        question = store.get(question_id)
        if question is None:
            not_found_ids.append(question_id)
            continue
        if question.review_status == payload.status:
            unchanged += 1
            continue
        question.review_status = payload.status
        if store.upsert(question):
            updated += 1
        else:
            not_found_ids.append(question_id)

    logger.info(
        "Admin review-status update: %d → %s (%d unchanged, %d not found)",
        updated,
        payload.status,
        unchanged,
        len(not_found_ids),
    )

    return ReviewStatusUpdateResponse(
        success=True,
        updated_count=updated,
        unchanged_count=unchanged,
        not_found_count=len(not_found_ids),
        not_found_ids=not_found_ids,
    )


@router.post("/questions/set-category", response_model=SetCategoryResponse)
@limiter.limit("5/minute")
async def set_category(
    request: Request,
    payload: SetCategoryRequest,
    store: QuestionStore = Depends(get_question_store),
    _: str = Depends(verify_admin_key),
):
    """Re-categorize existing questions by ID (bulk, one category per question).

    The category filter the app exposes must match what the corpus actually
    holds, so corpus curation needs a way to move questions between taxonomy
    categories without re-importing. Same get + upsert path as the
    review-status endpoint: the stored embedding is reused, never recomputed.
    """
    updated = 0
    unchanged = 0
    not_found_ids: List[str] = []

    for assignment in payload.assignments:
        question = store.get(assignment.id)
        if question is None:
            not_found_ids.append(assignment.id)
            continue
        if question.category == assignment.category:
            unchanged += 1
            continue
        question.category = assignment.category
        if store.upsert(question):
            updated += 1
        else:
            not_found_ids.append(assignment.id)

    logger.info(
        "Admin set-category: %d updated (%d unchanged, %d not found)",
        updated,
        unchanged,
        len(not_found_ids),
    )

    return SetCategoryResponse(
        success=True,
        updated_count=updated,
        unchanged_count=unchanged,
        not_found_count=len(not_found_ids),
        not_found_ids=not_found_ids,
    )


@router.get("/questions")
@limiter.limit("5/minute")
async def list_questions(
    request: Request,
    store: QuestionStore = Depends(get_question_store),
    _: str = Depends(verify_admin_key),
    search: Optional[str] = None,
    topic: Optional[str] = None,
    review_status: Optional[str] = None,
    limit: int = 1000,
):

    all_questions = store.get_all(limit=limit)

    results = []
    for q in all_questions:
        if search and search.lower() not in q.question.lower():
            continue
        if topic and q.topic.lower() != topic.lower():
            continue
        if review_status and q.review_status != review_status:
            continue
        results.append(
            {
                "id": q.id,
                "question": q.question,
                "correct_answer": q.correct_answer,
                "topic": q.topic,
                "difficulty": q.difficulty,
                "type": q.type,
                "review_status": q.review_status,
                "possible_answers": q.possible_answers,
                "explanation": q.explanation,
            }
        )

    return {"total": len(results), "questions": results}


@router.get("/questions/stats", response_model=QuestionStats)
@limiter.limit("5/minute")
async def get_question_stats(
    request: Request,
    store: QuestionStore = Depends(get_question_store),
    _: str = Depends(verify_admin_key),
):

    # Get all questions
    all_questions = store.get_all(limit=10000)

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
        by_category=by_category,
    )


@router.delete("/questions/{question_id}")
@limiter.limit("5/minute")
async def delete_question(
    request: Request,
    question_id: str,
    store: QuestionStore = Depends(get_question_store),
    _: str = Depends(verify_admin_key),
):

    # Check if question exists
    question = store.get(question_id)
    if not question:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Question {question_id} not found",
        )

    # Delete question
    success = store.delete(question_id)

    if not success:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to delete question",
        )

    return {"success": True, "message": f"Deleted question {question_id}"}
