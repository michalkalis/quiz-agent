"""Web UI routes for question management."""

import json
from typing import Optional
from fastapi import APIRouter, Request, Form
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
import os
from datetime import datetime

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared"))

from quiz_shared.models.question import Question
from ..generation.storage import QuestionStorage

# Setup templates
current_dir = os.path.dirname(__file__)
templates_dir = os.path.join(current_dir, "templates")
templates = Jinja2Templates(directory=templates_dir)

# Initialize storage
storage = QuestionStorage()

# Create router
router = APIRouter(prefix="/web", tags=["web"])


@router.get("/", response_class=HTMLResponse)
async def home(
    request: Request,
    status: Optional[str] = None,
    difficulty: Optional[str] = None,
    topic: Optional[str] = None
):
    """Home page with question list."""
    # Build filters
    filters = {}
    if status:
        filters["review_status"] = status

    # Search questions
    questions = storage.search_questions(
        difficulty=difficulty,
        topic=topic,
        filters=filters,
        limit=1000
    )

    # Calculate quality scores separately (Pydantic models don't allow arbitrary attributes)
    quality_scores = {}
    for q in questions:
        quality_scores[q.id] = q.calculate_quality_score() if q.quality_ratings else None

    # Get stats
    all_questions = storage.get_all_questions(limit=2000)
    stats = {
        "total": len(all_questions),
        "pending": sum(1 for q in all_questions if q.review_status == "pending_review"),
        "approved": sum(1 for q in all_questions if q.review_status == "approved"),
        "rejected": sum(1 for q in all_questions if q.review_status == "rejected"),
    }

    return templates.TemplateResponse("home.html", {
        "request": request,
        "questions": questions,
        "quality_scores": quality_scores,
        "stats": stats,
        "filter_status": status,
        "filter_difficulty": difficulty,
        "filter_topic": topic,
        "active_page": "home"
    })


@router.get("/import", response_class=HTMLResponse)
async def import_page(request: Request):
    """Import page."""
    return templates.TemplateResponse("import.html", {
        "request": request,
        "active_page": "import"
    })


@router.post("/import", response_class=HTMLResponse)
async def import_questions(
    request: Request,
    json_data: str = Form(...),
    source: str = Form("chatgpt"),
    skip_duplicates: Optional[str] = Form(None)
):
    """Import questions from JSON."""
    try:
        # Parse JSON
        data = json.loads(json_data)

        # Extract questions array
        if "questions" in data:
            questions_data = data["questions"]
        else:
            questions_data = [data]

        # Convert to Question objects
        questions = []
        for q_data in questions_data:
            question = _dict_to_question(q_data, source=source)
            questions.append(question)

        # Import questions
        skip_dups = skip_duplicates == "true"
        approved, failed = storage.bulk_approve(questions, force=not skip_dups)

        message = f"Successfully imported {len(approved)} questions!"
        if failed:
            message += f" ({len(failed)} skipped as duplicates)"

        return templates.TemplateResponse("import.html", {
            "request": request,
            "active_page": "import",
            "message": message,
            "message_type": "success"
        })

    except json.JSONDecodeError as e:
        return templates.TemplateResponse("import.html", {
            "request": request,
            "active_page": "import",
            "message": f"Invalid JSON: {str(e)}",
            "message_type": "error"
        })
    except Exception as e:
        return templates.TemplateResponse("import.html", {
            "request": request,
            "active_page": "import",
            "message": f"Import failed: {str(e)}",
            "message_type": "error"
        })


@router.get("/review", response_class=HTMLResponse)
async def review_list(request: Request):
    """Review page - redirect to first pending question."""
    # Get first pending question
    pending = storage.search_questions(
        filters={"review_status": "pending_review"},
        limit=1
    )

    if pending:
        return RedirectResponse(url=f"/web/review/{pending[0].id}", status_code=302)
    else:
        # No pending questions, show empty state
        return templates.TemplateResponse("review.html", {
            "request": request,
            "question": None,
            "active_page": "review"
        })


@router.get("/review/{question_id}", response_class=HTMLResponse)
async def review_question(request: Request, question_id: str):
    """Review a specific question."""
    question = storage.get_question(question_id)

    if not question:
        return RedirectResponse(url="/web/review", status_code=302)

    # Get total pending count for progress indicator
    pending = storage.search_questions(
        filters={"review_status": "pending_review"},
        limit=1000
    )
    total_pending = len(pending)
    current_index = next((i + 1 for i, q in enumerate(pending) if q.id == question_id), 1)

    return templates.TemplateResponse("review.html", {
        "request": request,
        "question": question,
        "current_index": current_index,
        "total_pending": total_pending,
        "active_page": "review"
    })


@router.post("/review/{question_id}", response_class=HTMLResponse)
async def submit_review(
    request: Request,
    question_id: str,
    status: str = Form(...),
    surprise_factor: int = Form(...),
    clarity: int = Form(...),
    universal_appeal: int = Form(...),
    creativity: int = Form(...),
    review_notes: str = Form("")
):
    """Submit a review for a question."""
    question = storage.get_question(question_id)

    if not question:
        return RedirectResponse(url="/web/review", status_code=302)

    # Get next pending question BEFORE updating this one
    # This ensures we get the next question in the queue
    all_pending = storage.search_questions(
        filters={"review_status": "pending_review"},
        limit=1000
    )

    # Find next question after current one
    next_question = None
    for i, q in enumerate(all_pending):
        if q.id == question_id and i + 1 < len(all_pending):
            next_question = all_pending[i + 1]
            break

    # If current question is last or not found, use first pending (excluding current)
    if not next_question:
        next_question = next((q for q in all_pending if q.id != question_id), None)

    # Update review fields
    question.review_status = status
    question.reviewed_by = "admin"  # TODO: Get from auth
    question.reviewed_at = datetime.now()
    question.review_notes = review_notes if review_notes else None
    question.quality_ratings = {
        "surprise_factor": surprise_factor,
        "clarity": clarity,
        "universal_appeal": universal_appeal,
        "creativity": creativity
    }

    # Save
    storage.update_question(question)

    # Redirect to next pending question or back to review page if none left
    if next_question:
        return RedirectResponse(url=f"/web/review/{next_question.id}", status_code=303)
    else:
        return RedirectResponse(url="/web/review", status_code=303)


@router.get("/stats", response_class=HTMLResponse)
async def stats_page(request: Request):
    """Statistics page."""
    # Get all questions
    all_questions = storage.get_all_questions(limit=2000)

    # Calculate stats
    pending = sum(1 for q in all_questions if q.review_status == "pending_review")
    approved = sum(1 for q in all_questions if q.review_status == "approved")
    rejected = sum(1 for q in all_questions if q.review_status == "rejected")
    needs_revision = sum(1 for q in all_questions if q.review_status == "needs_revision")

    # Calculate average quality score for approved questions
    approved_questions = [q for q in all_questions if q.review_status == "approved"]
    quality_scores = [q.calculate_quality_score() for q in approved_questions if q.quality_ratings]
    avg_quality = sum(quality_scores) / len(quality_scores) if quality_scores else None

    stats = {
        "total": len(all_questions),
        "pending_review": pending,
        "approved": approved,
        "rejected": rejected,
        "needs_revision": needs_revision,
        "avg_quality_score": avg_quality
    }

    return templates.TemplateResponse("stats.html", {
        "request": request,
        "stats": stats,
        "active_page": "stats"
    })


# Helper functions

def _dict_to_question(data: dict, source: str = "imported") -> Question:
    """Convert dict to Question object."""
    import uuid

    # Extract reasoning and self_critique if present (from V2 CoT prompt)
    reasoning = data.get("reasoning", {})
    self_critique = data.get("self_critique", {})

    # Build generation metadata if available
    generation_metadata = {}
    if reasoning:
        generation_metadata["reasoning"] = reasoning
    if self_critique:
        generation_metadata["self_critique"] = self_critique
        generation_metadata["ai_score"] = self_critique.get("overall_score", 0)

    # Build quality ratings from self_critique if available
    quality_ratings = None
    if self_critique:
        quality_ratings = {
            "surprise_factor": self_critique.get("surprise_factor", 0),
            "universal_appeal": self_critique.get("universal_appeal", 0),
            "clever_framing": self_critique.get("clever_framing", 0),
            "educational_value": self_critique.get("educational_value", 0),
        }

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
        source=source,
        review_status="pending_review",
        quality_ratings=quality_ratings,
        generation_metadata=generation_metadata if generation_metadata else None
    )
