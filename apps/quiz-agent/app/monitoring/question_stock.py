"""Question stock early warning (#199).

Generating questions takes lead time, so the founder has to hear that stock is
running low before a player hits the wall (the quiz ends early when the
retriever runs out, `flow.py` `no_more_questions`). This module counts what the
serve path could actually deliver and raises a Sentry issue (which emails the
founder) when:

- a (language × category) cell has fewer playable questions than the minimum, or
- a language has too few *fresh* entertainment questions, i.e. ones whose #195
  boost window still runs `fresh_horizon_days` from now.

The numbers are only worth alerting on if they equal what `get_next_question`
would serve, so every count goes through `QuestionRetriever.count_available`
with a throwaway `QuizSession` probe built exactly like
`POST /questions/availability` does: default (App Store) build channel, so only
approved questions, and no exclusions.

Shape mirrors `provider_balances.py`: fetch → evaluate → `report_to_sentry`
with a stable fingerprint per problem → in-process daily loop.
"""

from __future__ import annotations

import asyncio
import logging
import random
from datetime import UTC, datetime, timedelta
from typing import Literal

import sentry_sdk
from pydantic import BaseModel
from quiz_shared.languages import servable_quiz_languages
from quiz_shared.models.session import QuizSession

from ..api.admin import CATEGORY_TAXONOMY
from ..config import Settings
from ..retrieval.question_retriever import QuestionRetriever

logger = logging.getLogger(__name__)

FRESH_CATEGORY = "entertainment"

# #195 stores a permanent boost as 9999-01-01 (Python cannot hold Postgres
# `infinity`). Such a row never expires, so it is not fresh *stock* that will
# run out; counting it would hide the very shortage this check exists for. Any
# date past this floor is treated as permanent.
_PERMANENT_BOOST_FLOOR = datetime(9000, 1, 1, tzinfo=UTC)


class StockThresholds(BaseModel):
    min_per_cell: int
    min_fresh: int
    fresh_horizon_days: int


class LanguageStock(BaseModel):
    language: str
    categories: dict[str, int]
    fresh_entertainment: int


class StockAlert(BaseModel):
    kind: Literal["cell", "fresh"]
    language: str
    category: str
    count: int
    threshold: int
    message: str

    def fingerprint(self) -> list[str]:
        """One issue per problem, independent of the count: a cell that stays
        low for a week is one Sentry issue (one email), not seven."""
        if self.kind == "fresh":
            return ["question-stock", "fresh", self.language]
        return ["question-stock", "cell", self.language, self.category]


class StockReport(BaseModel):
    checked_at: datetime
    thresholds: StockThresholds
    languages: list[LanguageStock]
    alerts: list[StockAlert]


def evaluate(
    languages: list[LanguageStock], thresholds: StockThresholds
) -> list[StockAlert]:
    """Alerts for every cell below `min_per_cell` and every language whose
    fresh stock is below `min_fresh`. Exactly at the minimum is not low."""
    alerts: list[StockAlert] = []
    for lang in languages:
        for category, count in lang.categories.items():
            if count < thresholds.min_per_cell:
                alerts.append(
                    StockAlert(
                        kind="cell",
                        language=lang.language,
                        category=category,
                        count=count,
                        threshold=thresholds.min_per_cell,
                        message=(
                            f"Question stock low: {lang.language}/{category} has "
                            f"{count} playable questions (minimum "
                            f"{thresholds.min_per_cell})"
                        ),
                    )
                )
        if lang.fresh_entertainment < thresholds.min_fresh:
            alerts.append(
                StockAlert(
                    kind="fresh",
                    language=lang.language,
                    category=FRESH_CATEGORY,
                    count=lang.fresh_entertainment,
                    threshold=thresholds.min_fresh,
                    message=(
                        f"Fresh entertainment stock low: {lang.language} has "
                        f"{lang.fresh_entertainment} questions still boosted in "
                        f"{thresholds.fresh_horizon_days} days (minimum "
                        f"{thresholds.min_fresh})"
                    ),
                )
            )
    return alerts


def _probe(language: str, category: str) -> QuizSession:
    """Throwaway session, same inputs `/questions/availability` builds: the
    default build channel (approved only), no exclusions, not persisted.

    Counts the "skip local questions" pool (#206): it is the smaller one, so a
    player who switched local questions off runs dry first and the warning
    has to come in time for them too."""
    return QuizSession(
        session_id="stock-probe",
        current_difficulty="medium",
        language=language,
        category=category,
        preferred_categories=[category],
        skip_local_questions=True,
    )


async def fetch_question_stock(
    retriever: QuestionRetriever,
    settings: Settings,
    *,
    now: datetime | None = None,
    languages: tuple[str, ...] | None = None,
) -> StockReport:
    """Count stock per servable language and evaluate it.

    Counts run one after another: ~24 cheap COUNTs once a day are not worth
    competing with the live quiz for pool connections. A failing count raises
    (fail loud) instead of reporting a partial table as healthy.
    """
    now = now or datetime.now(UTC)
    thresholds = StockThresholds(
        min_per_cell=settings.question_stock_min_per_cell,
        min_fresh=settings.question_stock_min_fresh,
        fresh_horizon_days=settings.question_stock_fresh_horizon_days,
    )
    # Still boosted after the horizon, but not "forever".
    fresh_window = {
        "boost_until": {
            "$gt": now + timedelta(days=thresholds.fresh_horizon_days),
            "$lt": _PERMANENT_BOOST_FLOOR,
        }
    }

    stock: list[LanguageStock] = []
    for language in languages if languages is not None else servable_quiz_languages():
        categories = {
            category: await retriever.count_available(_probe(language, category))
            for category in CATEGORY_TAXONOMY
        }
        fresh = await retriever.count_available(
            _probe(language, FRESH_CATEGORY), extra_filters=fresh_window
        )
        stock.append(
            LanguageStock(
                language=language, categories=categories, fresh_entertainment=fresh
            )
        )
    return StockReport(
        checked_at=now,
        thresholds=thresholds,
        languages=stock,
        alerts=evaluate(stock, thresholds),
    )


def report_to_sentry(report: StockReport) -> None:
    """One Sentry issue per low cell and per low fresh stock (stable
    fingerprint). An empty cell is an error (the quiz ends there), low a
    warning."""
    for alert in report.alerts:
        sentry_sdk.capture_message(
            alert.message,
            level="error" if alert.count == 0 else "warning",
            fingerprint=alert.fingerprint(),
            tags={
                "language": alert.language,
                "category": alert.category,
                "stock_kind": alert.kind,
            },
            contexts={"stock": alert.model_dump(mode="json")},
        )
        logger.warning(alert.message)


async def run_daily_stock_check(
    settings: Settings, retriever: QuestionRetriever
) -> None:
    """Background loop: shortly after startup, then every ~24 h. Runs off the
    request path; the first check waits so it never delays boot."""
    await asyncio.sleep(settings.question_stock_initial_delay_s)
    while True:
        try:
            report_to_sentry(await fetch_question_stock(retriever, settings))
        except Exception:
            logger.exception("Question stock check crashed")
        await asyncio.sleep(24 * 3600 + random.uniform(0, 600))
