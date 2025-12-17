"""FastAPI routes for Question Generator."""

import time
from typing import Dict, Any
from fastapi import APIRouter, HTTPException

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared"))

from quiz_shared.models.question import Question

from .schemas import (
    GenerateRequest, GenerateResponse, QuestionResponse,
    ImportRequest, ImportResponse,
    ApproveRequest, ApproveResponse,
    SearchResponse, DuplicatesResponse, DuplicateInfo,
    AdvancedGenerateRequest, AdvancedGenerateResponse, AdvancedQuestionResponse,
    ReviewRequest, ReviewResponse, PendingReviewResponse, ReviewStats
)
from ..generation.generator import QuestionGenerator
from ..generation.advanced_generator import AdvancedQuestionGenerator
from ..generation.storage import QuestionStorage


# Initialize services
generator = QuestionGenerator()
advanced_generator = AdvancedQuestionGenerator(
    generation_model="gpt-4o",
    critique_model="gpt-4o-mini",
    generation_temperature=0.8,
    critique_temperature=0.3
)
storage = QuestionStorage()

# Create router
router = APIRouter(prefix="/api/v1", tags=["questions"])


@router.post("/generate", response_model=GenerateResponse)
async def generate_questions(request: GenerateRequest):
    """Generate quiz questions using LLM.

    Args:
        request: Generation parameters

    Returns:
        Generated questions with metadata
    """
    start_time = time.time()

    try:
        questions = await generator.generate_questions(
            count=request.count,
            difficulty=request.difficulty,
            topics=request.topics,
            categories=request.categories,
            question_type=request.type,
            excluded_topics=request.excluded_topics
        )

        # Convert to response format
        question_responses = [
            _question_to_response(q) for q in questions
        ]

        generation_time = time.time() - start_time

        return GenerateResponse(
            questions=question_responses,
            generation_time_seconds=round(generation_time, 2)
        )

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Generation failed: {str(e)}")


@router.post("/generate/advanced", response_model=AdvancedGenerateResponse)
async def generate_questions_advanced(request: AdvancedGenerateRequest):
    """Generate quiz questions using advanced multi-stage pipeline.

    Pipeline:
    1. Generate N x count questions with Chain of Thought reasoning
    2. Critique each question with LLM judge
    3. Select top-scoring questions
    4. Store as pending_review

    Args:
        request: Advanced generation parameters

    Returns:
        Generated questions with quality metadata and statistics
    """
    start_time = time.time()

    try:
        questions = await advanced_generator.generate_questions(
            count=request.count,
            difficulty=request.difficulty,
            topics=request.topics,
            categories=request.categories,
            question_type=request.type,
            excluded_topics=request.excluded_topics,
            enable_best_of_n=request.enable_best_of_n,
            n_multiplier=request.n_multiplier,
            min_quality_score=request.min_quality_score,
        )

        # Convert to response format
        question_responses = [
            _question_to_advanced_response(q) for q in questions
        ]

        generation_time = time.time() - start_time

        # Calculate statistics
        total_generated = request.count * request.n_multiplier if request.enable_best_of_n else request.count
        ai_scores = [q.get_ai_score() for q in questions if q.get_ai_score() is not None]
        avg_ai_score = sum(ai_scores) / len(ai_scores) if ai_scores else None

        stats = {
            "generated_count": total_generated,
            "selected_count": len(questions),
            "avg_ai_score": round(avg_ai_score, 2) if avg_ai_score else None,
            "min_ai_score": round(min(ai_scores), 2) if ai_scores else None,
            "max_ai_score": round(max(ai_scores), 2) if ai_scores else None,
        }

        return AdvancedGenerateResponse(
            questions=question_responses,
            generation_time_seconds=round(generation_time, 2),
            stats=stats
        )

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Advanced generation failed: {str(e)}")


@router.post("/import", response_model=ImportResponse)
async def import_questions(request: ImportRequest):
    """Import questions from JSON (e.g., ChatGPT output).

    Args:
        request: List of question dicts

    Returns:
        Import summary with pending review IDs
    """
    try:
        questions = []
        for q_dict in request.questions:
            # Convert dict to Question object
            question = _dict_to_question(q_dict, source=request.source)
            questions.append(question)

        # Store as pending (temp IDs)
        pending_ids = [q.id for q in questions]

        # TODO: Implement pending review storage
        # For now, just return the IDs

        return ImportResponse(
            imported_count=len(questions),
            pending_review=pending_ids
        )

    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Import failed: {str(e)}")


@router.post("/questions/approve", response_model=ApproveResponse)
async def approve_questions(request: ApproveRequest):
    """Approve and store questions.

    Checks for duplicates unless force=True.

    Args:
        request: Question IDs to approve with optional edits

    Returns:
        Approval summary
    """
    try:
        approved_ids = []
        failed = []

        for qid in request.question_ids:
            # Get question (from temp storage or database)
            question = storage.get_question(qid)

            if not question:
                failed.append({"id": qid, "reason": "Question not found"})
                continue

            # Apply edits if provided
            if request.edits and qid in request.edits:
                edits = request.edits[qid]
                for key, value in edits.items():
                    if hasattr(question, key):
                        setattr(question, key, value)

            # Approve question
            success, error, duplicates = storage.approve_question(
                question,
                force=request.force
            )

            if success:
                approved_ids.append(question.id)
            else:
                reason = error or "Unknown error"
                if duplicates:
                    dup_questions = [d[0].question[:50] for d, _ in duplicates[:2]]
                    reason = f"Duplicates found: {', '.join(dup_questions)}..."
                failed.append({"id": qid, "reason": reason})

        return ApproveResponse(
            approved_count=len(approved_ids),
            question_ids=approved_ids,
            failed=failed if failed else None
        )

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Approval failed: {str(e)}")


@router.get("/questions/search", response_model=SearchResponse)
async def search_questions(
    query: str = None,
    topic: str = None,
    category: str = None,
    difficulty: str = None,
    limit: int = 10
):
    """Search questions with semantic search and filters.

    Args:
        query: Semantic search query
        topic: Filter by topic
        category: Filter by category
        difficulty: Filter by difficulty
        limit: Max results

    Returns:
        Matching questions
    """
    try:
        questions = storage.search_questions(
            query=query,
            topic=topic,
            category=category,
            difficulty=difficulty,
            limit=limit
        )

        question_responses = [
            _question_to_response(q) for q in questions
        ]

        return SearchResponse(
            questions=question_responses,
            total=len(questions)
        )

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Search failed: {str(e)}")


@router.post("/questions/duplicates", response_model=DuplicatesResponse)
async def check_duplicates(question_text: str, threshold: float = 0.85):
    """Check if question text is duplicate.

    Args:
        question_text: Question to check
        threshold: Similarity threshold

    Returns:
        List of similar questions
    """
    try:
        # Create temporary question
        temp_question = Question(
            id="temp_check",
            question=question_text,
            correct_answer="",
            topic="",
            category="",
            difficulty=""
        )

        duplicates = storage.check_duplicates(temp_question, threshold)

        duplicate_infos = [
            DuplicateInfo(
                question=_question_to_response(q),
                similarity=round(score, 3)
            )
            for q, score in duplicates
        ]

        return DuplicatesResponse(
            duplicates=duplicate_infos,
            is_duplicate=len(duplicates) > 0
        )

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Duplicate check failed: {str(e)}")


@router.delete("/questions/{question_id}")
async def delete_question(question_id: str):
    """Delete a question.

    Args:
        question_id: Question ID

    Returns:
        Success message
    """
    success = storage.delete_question(question_id)

    if success:
        return {"message": "Question deleted", "question_id": question_id}
    else:
        raise HTTPException(status_code=404, detail="Question not found")


@router.get("/export/chatgpt")
async def export_chatgpt_prompt(
    count: int = 10,
    difficulty: str = "medium",
    topics: str = None,
    categories: str = None,
    type: str = "text"
):
    """Export prompt for manual ChatGPT usage.

    Args:
        count: Number of questions
        difficulty: Difficulty level
        topics: Comma-separated topics
        categories: Comma-separated categories
        type: Question type

    Returns:
        Prompt text ready to copy-paste
    """
    topic_list = topics.split(",") if topics else None
    category_list = categories.split(",") if categories else None

    prompt = generator.export_for_chatgpt(
        count=count,
        difficulty=difficulty,
        topics=topic_list,
        categories=category_list,
        question_type=type
    )

    return {"prompt": prompt}


# Review Workflow Endpoints

@router.get("/reviews/pending", response_model=PendingReviewResponse)
async def list_pending_reviews(limit: int = 50, offset: int = 0):
    """List questions pending review.

    Args:
        limit: Max results
        offset: Pagination offset

    Returns:
        Questions with status pending_review or needs_revision
    """
    try:
        # Search for pending questions
        pending_questions = storage.search_questions(
            query=None,
            filters={"review_status": "pending_review"},
            limit=limit
        )

        question_responses = [
            _question_to_advanced_response(q) for q in pending_questions
        ]

        return PendingReviewResponse(
            questions=question_responses,
            total=len(pending_questions)
        )

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to list pending reviews: {str(e)}")


@router.post("/reviews/submit", response_model=ReviewResponse)
async def submit_review(request: ReviewRequest):
    """Submit a review for a question (approve/reject/needs revision).

    Args:
        request: Review data with ratings and status

    Returns:
        Review confirmation
    """
    try:
        from datetime import datetime

        # Get question
        question = storage.get_question(request.question_id)

        if not question:
            raise HTTPException(status_code=404, detail="Question not found")

        # Update review fields
        question.review_status = request.status
        question.reviewed_by = request.reviewer_id
        question.reviewed_at = datetime.now()
        question.review_notes = request.review_notes
        question.quality_ratings = request.quality_ratings

        # Save updated question
        storage.update_question(question)

        return ReviewResponse(
            question_id=request.question_id,
            status=request.status,
            message=f"Question {request.status}"
        )

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Review submission failed: {str(e)}")


@router.get("/reviews/stats", response_model=ReviewStats)
async def get_review_stats():
    """Get statistics about review workflow.

    Returns:
        Counts of questions by review status
    """
    try:
        # Get all questions
        all_questions = storage.get_all_questions()

        # Count by status
        pending = sum(1 for q in all_questions if q.review_status == "pending_review")
        approved = sum(1 for q in all_questions if q.review_status == "approved")
        rejected = sum(1 for q in all_questions if q.review_status == "rejected")
        needs_revision = sum(1 for q in all_questions if q.review_status == "needs_revision")

        # Calculate average quality score for approved questions
        approved_questions = [q for q in all_questions if q.review_status == "approved"]
        quality_scores = [q.calculate_quality_score() for q in approved_questions if q.quality_ratings]
        avg_quality = sum(quality_scores) / len(quality_scores) if quality_scores else None

        return ReviewStats(
            pending_review=pending,
            approved=approved,
            rejected=rejected,
            needs_revision=needs_revision,
            avg_quality_score=round(avg_quality, 2) if avg_quality else None
        )

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to get stats: {str(e)}")


# Helper functions

def _question_to_response(question: Question) -> QuestionResponse:
    """Convert Question model to API response."""
    return QuestionResponse(
        id=question.id,
        question=question.question,
        type=question.type,
        correct_answer=question.correct_answer if isinstance(question.correct_answer, str) else str(question.correct_answer),
        topic=question.topic,
        category=question.category,
        difficulty=question.difficulty,
        possible_answers=question.possible_answers,
        alternative_answers=question.alternative_answers,
        tags=question.tags,
        quality_score=question.calculate_avg_rating() if question.user_ratings else None
    )


def _question_to_advanced_response(question: Question) -> AdvancedQuestionResponse:
    """Convert Question model to Advanced API response with review metadata."""
    return AdvancedQuestionResponse(
        id=question.id,
        question=question.question,
        type=question.type,
        correct_answer=question.correct_answer if isinstance(question.correct_answer, str) else str(question.correct_answer),
        topic=question.topic,
        category=question.category,
        difficulty=question.difficulty,
        possible_answers=question.possible_answers,
        alternative_answers=question.alternative_answers,
        tags=question.tags,
        quality_score=question.calculate_avg_rating() if question.user_ratings else None,
        review_status=question.review_status,
        quality_ratings=question.quality_ratings,
        generation_metadata=question.generation_metadata
    )


def _dict_to_question(data: Dict[str, Any], source: str = "imported") -> Question:
    """Convert dict to Question object."""
    import uuid

    return Question(
        id=f"temp_{uuid.uuid4().hex[:8]}",
        question=data.get("question", ""),
        type=data.get("type", "text"),
        correct_answer=data.get("correct_answer", ""),
        possible_answers=data.get("possible_answers"),
        alternative_answers=data.get("alternative_answers", []),
        topic=data.get("topic", "General"),
        category=data.get("category", "general"),
        difficulty=data.get("difficulty", "medium"),
        tags=data.get("tags", []),
        source=source
    )
