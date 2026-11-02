"""Public, unauthenticated feed of this week's fresh entertainment questions (#223).

The static website (trubbo.app) rebuilds weekly in GitHub Actions and bakes
these into its question pages. Read-only: no writes, no LLM calls. Only rows the
App Store app itself may serve are returned (selection lives in
``PgvectorQuestionStore.fresh_public_entertainment``) — custom-pack and
unreviewed rows must never leak through a door that needs no login.
"""

from __future__ import annotations

from typing import Any, Literal

from fastapi import APIRouter, Depends, Query, Request, Response
from pydantic import BaseModel

from ...rate_limit import limiter
from ...retrieval.question_retriever import QuestionRetriever
from ..deps import get_question_retriever

router = APIRouter(prefix="/public", tags=["Public"])

_CACHE_CONTROL = "public, max-age=3600"


class FreshQuestion(BaseModel):
    id: str
    question: str
    answer: str
    explanation: str
    source_url: str
    created_at: str


class FreshQuestionsResponse(BaseModel):
    language: str
    questions: list[FreshQuestion]


def _display_answer(headline: str | None, correct: Any) -> str:
    """Headline answer when set, else the first correct answer (string or list)."""
    if headline and headline.strip():
        return headline.strip()
    if isinstance(correct, list):
        correct = correct[0] if correct else ""
    return str(correct)


@router.get("/fresh-questions", response_model=FreshQuestionsResponse)
@limiter.limit("30/minute")
async def fresh_questions(
    request: Request,
    response: Response,
    language: Literal["sk", "cs", "en"],
    limit: int = Query(10, ge=1, le=20),
    retriever: QuestionRetriever = Depends(get_question_retriever),
) -> FreshQuestionsResponse:
    rows = await retriever.fresh_public_entertainment(language, limit)
    response.headers["Cache-Control"] = _CACHE_CONTROL
    return FreshQuestionsResponse(
        language=language,
        questions=[
            FreshQuestion(
                id=r["id"],
                question=r["question"],
                answer=_display_answer(r["headline_answer"], r["correct_answer"]),
                explanation=r["explanation"],
                source_url=r["source_url"],
                created_at=r["created_at"].isoformat(),
            )
            for r in rows
        ],
    )
