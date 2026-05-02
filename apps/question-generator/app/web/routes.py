"""Web UI routes for question management."""

import json
from typing import Optional
from fastapi import APIRouter, Request, Form
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
import os
from datetime import datetime

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
    """Import questions as pending review (does NOT touch ChromaDB)."""
    try:
        data = json.loads(json_data)

        if "questions" in data:
            questions_data = data["questions"]
        else:
            questions_data = [data]

        added = 0
        for q_data in questions_data:
            question = Question.from_dict(q_data, source=source)
            if storage.add_pending(question):
                added += 1

        message = f"Imported {added} questions to pending review."
        if added < len(questions_data):
            message += f" ({len(questions_data) - added} failed.)"

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
    pending = storage.list_pending(status="pending_review", limit=1)

    if pending:
        return RedirectResponse(url=f"/web/review/{pending[0].id}", status_code=302)
    else:
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

    pending = storage.list_pending(status="pending_review", limit=1000)
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

    # Snapshot the queue BEFORE mutating so the redirect lands on a still-pending row.
    all_pending = storage.list_pending(status="pending_review", limit=1000)

    next_question = None
    for i, q in enumerate(all_pending):
        if q.id == question_id and i + 1 < len(all_pending):
            next_question = all_pending[i + 1]
            break
    if not next_question:
        next_question = next((q for q in all_pending if q.id != question_id), None)

    question.reviewed_by = "admin"  # TODO: Get from auth
    question.reviewed_at = datetime.now()
    question.review_notes = review_notes if review_notes else None
    question.quality_ratings = {
        "surprise_factor": surprise_factor,
        "clarity": clarity,
        "universal_appeal": universal_appeal,
        "creativity": creativity
    }

    if status == "approved":
        storage.approve_question(question, force=True)
    else:
        question.review_status = status
        storage.update_question(question)

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


