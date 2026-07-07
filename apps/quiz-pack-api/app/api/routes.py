"""FastAPI routes for Question Generator."""

import time
from fastapi import APIRouter, Depends, HTTPException, Request

from quiz_shared.models.question import Question
from quiz_shared.llm import factory as llm_factory

from .schemas import (
    GenerateRequest, GenerateResponse, QuestionResponse,
    ImportRequest, ImportResponse,
    SearchResponse,
    AdvancedGenerateRequest, AdvancedGenerateResponse, AdvancedQuestionResponse,
    ReviewRequest, ReviewResponse, PendingReviewResponse, ReviewStats,
    VerifyRequest, VerifyBatchRequest, VerifyResponse, VerifyBatchResponse,
    VerifyBatchItem, SourceInfo,
)
from ..generation.advanced_generator import AdvancedQuestionGenerator
from ..generation.storage import QuestionStorage
from ..verification.fact_verifier import FactVerifier
from .deps import require_admin
from ..rate_limit import limiter
from .. import feature_flags


def _build_advanced_generator() -> AdvancedQuestionGenerator:
    """Construct the generator with config-driven models (issue #72 P1.1, Lever A).

    The model ids come from the dormant Lever-A flags; with no env set the flags
    return ``None`` so we fall back to the factory's canonical role defaults
    (``gpt-4o`` / ``gpt-4o-mini``) and output is unchanged. An override (e.g.
    ``GENERATION_MODEL=claude-opus-4-8``) is a direct-provider id — its
    OpenRouter slug lives in the factory's ``_REMAP_OPENROUTER``, never here,
    per the #53 contract.
    """
    return AdvancedQuestionGenerator(
        generation_model=feature_flags.generation_model() or llm_factory.GEN,
        critique_model=feature_flags.critique_model() or llm_factory.CRITIQUE,
        generation_temperature=0.8,
        critique_temperature=0.3,
    )


# Initialize services
advanced_generator = _build_advanced_generator()
storage = QuestionStorage()
fact_verifier = FactVerifier()

# Create router — every /api/v1 question route is admin-gated (#65).
router = APIRouter(prefix="/api/v1", tags=["questions"], dependencies=[Depends(require_admin)])


@router.post("/generate", response_model=GenerateResponse)
@limiter.limit("10/minute")
async def generate_questions(request: Request, body: GenerateRequest):
    """Generate quiz questions using LLM.

    Args:
        body: Generation parameters

    Returns:
        Generated questions with metadata
    """
    start_time = time.time()

    try:
        questions = await advanced_generator.generate_questions(
            count=body.count,
            difficulty=body.difficulty,
            topics=body.topics,
            categories=body.categories,
            question_type=body.type,
            excluded_topics=body.excluded_topics,
            enable_best_of_n=False,
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
@limiter.limit("10/minute")
async def generate_questions_advanced(request: Request, body: AdvancedGenerateRequest):
    """Generate quiz questions using advanced multi-stage pipeline.

    Pipeline:
    1. Generate N x count questions with Chain of Thought reasoning
    2. Critique each question with LLM judge
    3. Select top-scoring questions
    4. Store as pending_review

    Args:
        body: Advanced generation parameters

    Returns:
        Generated questions with quality metadata and statistics
    """
    start_time = time.time()

    try:
        questions = await advanced_generator.generate_questions(
            count=body.count,
            difficulty=body.difficulty,
            topics=body.topics,
            categories=body.categories,
            question_type=body.type,
            excluded_topics=body.excluded_topics,
            enable_best_of_n=body.enable_best_of_n,
            n_multiplier=body.n_multiplier,
            min_quality_score=body.min_quality_score,
        )

        # Convert to response format
        question_responses = [
            _question_to_advanced_response(q) for q in questions
        ]

        generation_time = time.time() - start_time

        # Calculate statistics
        total_generated = body.count * body.n_multiplier if body.enable_best_of_n else body.count
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
        pending_ids: list[str] = []
        for q_dict in request.questions:
            question = Question.from_dict(q_dict, source=request.source)
            if storage.add_pending(question):
                pending_ids.append(question.id)

        return ImportResponse(
            imported_count=len(pending_ids),
            pending_review=pending_ids
        )

    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Import failed: {str(e)}")


@router.post("/questions/approve")
async def retired_questions_approve():
    """Retired (#41 D4) — ChromaDB approval path is gone.

    The future #42/#30 review flow writes approved questions to pgvector via
    `PgvectorQuestionStore.upsert`.
    """
    raise HTTPException(
        status_code=410,
        detail="Retired with the ChromaDB decommission (#41). The future review "
               "flow (#42/#30) writes approved questions to pgvector.",
    )


@router.get("/questions/search", response_model=SearchResponse)
async def search_questions(
    query: str = None,
    topic: str = None,
    category: str = None,
    difficulty: str = None,
    limit: int = 10
):
    """List pending-store questions matching scalar filters.

    Args:
        query: Retired (#41) — semantic search went away with ChromaDB; 410 if set
        topic: Filter by topic
        category: Filter by category
        difficulty: Filter by difficulty
        limit: Max results

    Returns:
        Matching questions
    """
    if query is not None:
        raise HTTPException(
            status_code=410,
            detail="Semantic search retired with the ChromaDB decommission (#41); "
                   "approved questions live in pgvector. Use scalar filters only.",
        )
    try:
        questions = storage.search_questions(
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


@router.post("/questions/duplicates")
async def retired_questions_duplicates():
    """Retired (#41) — the ad-hoc duplicate check ran on ChromaDB.

    Duplicate detection lives in the order pipeline's `DedupStage` over
    pgvector.
    """
    raise HTTPException(
        status_code=410,
        detail="Retired with the ChromaDB decommission (#41). Duplicate "
               "detection runs in the generation pipeline's DedupStage over pgvector.",
    )


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
        pending_questions = storage.list_pending(
            status="pending_review",
            limit=limit,
            offset=offset,
        )
        total = storage.count_pending(status="pending_review")

        question_responses = [
            _question_to_advanced_response(q) for q in pending_questions
        ]

        return PendingReviewResponse(
            questions=question_responses,
            total=total
        )

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to list pending reviews: {str(e)}")


@router.post("/reviews/submit", response_model=ReviewResponse)
async def submit_review(request: ReviewRequest):
    """Submit a review for a question (reject/needs revision).

    The question stays in `PendingStore` with its new status. Approval is
    retired (#41 D4) — the future #42/#30 review flow promotes to pgvector.
    """
    try:
        from datetime import datetime

        if request.status == "approved":
            raise HTTPException(
                status_code=410,
                detail="Approval retired with the ChromaDB decommission (#41). "
                       "The future review flow (#42/#30) writes approved "
                       "questions to pgvector.",
            )

        question = storage.get_question(request.question_id)

        if not question:
            raise HTTPException(status_code=404, detail="Question not found")

        question.reviewed_by = request.reviewer_id
        question.reviewed_at = datetime.now()
        question.review_notes = request.review_notes
        question.quality_ratings = request.quality_ratings

        question.review_status = request.status
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

    Counts cover the pending store only (#41) — approved questions live in
    pgvector and are not aggregated here.

    Returns:
        Counts of questions by review status
    """
    try:
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


# Verification Endpoints

@router.post("/verify", response_model=VerifyResponse)
@limiter.limit("10/minute")
async def verify_question(request: Request, body: VerifyRequest):
    """Verify a single question-answer pair using Tavily + Gemini Flash.

    Returns verdict (verified/likely_correct/uncertain/likely_wrong/wrong)
    with confidence score and source URLs.
    """
    try:
        result = await fact_verifier.verify(
            question=body.question,
            claimed_answer=body.correct_answer,
            topic=body.topic,
        )
        return VerifyResponse(
            verdict=result.verdict,
            confidence=result.confidence,
            sources=[
                SourceInfo(
                    url=s.get("url", ""),
                    excerpt=s.get("excerpt", ""),
                    agrees_with_answer=s.get("agrees_with_answer", False),
                    relevance_score=s.get("relevance_score", 0.0),
                )
                for s in result.sources
            ],
            alternative_answers=result.alternative_answers,
            notes=result.notes,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Verification failed: {str(e)}")


@router.post("/verify/batch", response_model=VerifyBatchResponse)
@limiter.limit("10/minute")
async def verify_batch(request: Request, body: VerifyBatchRequest):
    """Verify a batch of question-answer pairs.

    Each item needs: question, correct_answer, id (optional), topic (optional).
    """
    try:
        raw_results = await fact_verifier.verify_batch(body.questions)

        items = []
        verified = wrong = uncertain = 0

        for r in raw_results:
            v = r["verification"]
            if v.verdict in ("verified", "likely_correct"):
                verified += 1
            elif v.verdict in ("wrong", "likely_wrong"):
                wrong += 1
            else:
                uncertain += 1

            items.append(
                VerifyBatchItem(
                    id=r["id"],
                    question=r["question"],
                    claimed_answer=r["claimed_answer"],
                    verification=VerifyResponse(
                        verdict=v.verdict,
                        confidence=v.confidence,
                        sources=[
                            SourceInfo(
                                url=s.get("url", ""),
                                excerpt=s.get("excerpt", ""),
                                agrees_with_answer=s.get("agrees_with_answer", False),
                                relevance_score=s.get("relevance_score", 0.0),
                            )
                            for s in v.sources
                        ],
                        alternative_answers=v.alternative_answers,
                        notes=v.notes,
                    ),
                )
            )

        return VerifyBatchResponse(
            results=items,
            verified_count=verified,
            wrong_count=wrong,
            uncertain_count=uncertain,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Batch verification failed: {str(e)}")


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
        generation_metadata=question.generation_metadata.model_dump() if question.generation_metadata else None
    )
