"""#242 — ``GET /api/v1/categories/extra?language=sk``: the free rotating
categories on offer now (``app/extra_categories.py``), for the caller's build
channel (``X-Build-Channel``, as at session creation). Not in ``/app-config``:
that body does not differ by language or channel. Switch off or a language
with nothing on offer = an empty list, never an error.
"""

from __future__ import annotations

from typing import List, Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel

from ...config import get_settings
from ...extra_categories import (
    catalog_entries,
    extra_categories_on,
    extra_counts,
    offered,
    utc_today,
)
from ...family.rounds import build_channel
from ...retrieval.question_retriever import QuestionRetriever
from ..deps import get_auth_sessionmaker, get_question_retriever

router = APIRouter()


class ExtraCategory(BaseModel):
    key: str
    name: str
    until: str | None = None  # ISO date, the last day on offer


class ExtraCategoriesResponse(BaseModel):
    categories: list[ExtraCategory]


@router.get("/categories/extra", response_model=ExtraCategoriesResponse)
async def extra_categories(
    request: Request,
    language: str = "en",
    question_retriever: QuestionRetriever = Depends(get_question_retriever),
    sessionmaker=Depends(get_auth_sessionmaker),
) -> ExtraCategoriesResponse:
    language = language.strip().lower()
    today = utc_today()
    if not offered(language, today) or not await extra_categories_on(
        get_settings(), sessionmaker
    ):
        return ExtraCategoriesResponse(categories=[])
    counts = await extra_counts(
        question_retriever, language, build_channel(request.headers)
    )
    return ExtraCategoriesResponse(categories=catalog_entries(language, counts, today))
