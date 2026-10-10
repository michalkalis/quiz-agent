"""Admin view of question stock per language × category (#199)."""

from __future__ import annotations

from fastapi import APIRouter, Depends

from ...config import get_settings
from ...monitoring.question_stock import StockReport, fetch_question_stock
from ...retrieval.question_retriever import QuestionRetriever
from ..admin import verify_admin_key
from ..deps import get_question_retriever

router = APIRouter()


@router.get("/admin/question-stock", response_model=StockReport)
async def question_stock(
    _: str = Depends(verify_admin_key),
    retriever: QuestionRetriever = Depends(get_question_retriever),
) -> StockReport:
    """On-demand version of the daily check: playable questions per language
    and category, fresh entertainment per language, thresholds, and the alerts
    the daily check would raise right now."""
    return await fetch_question_stock(retriever, get_settings())
