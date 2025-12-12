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
    SearchResponse, DuplicatesResponse, DuplicateInfo
)
from ..generation.generator import QuestionGenerator
from ..generation.storage import QuestionStorage


# Initialize services
generator = QuestionGenerator()
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
