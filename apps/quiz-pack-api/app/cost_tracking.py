"""Per-order cost capture (#95 Session 1, founder decision 5).

Two measured components, one tracker:

- **Tavily** — every actual `client.search` call reports its credit cost here
  (advanced search = 2 credits, PAYG $8/1000 credits). This replaces the old
  flat 1¢-per-order estimate in SourcingStage, which missed the per-question
  verification searches entirely (~30+ calls per pack).
- **OpenRouter** — the pipeline calls LLMs through six different client
  objects (LangChain + native SDK), so instead of instrumenting every call
  site we snapshot the account's lifetime usage from the OpenRouter credits
  API before and after the run; the delta is the measured all-in LLM spend.
  Caveat: the delta covers the whole account for that window, so concurrent
  traffic on the same key (another order, live quiz-agent evaluation calls)
  leaks in. Acceptable at founder-only scale; revisit before real users.

The tracker rides a contextvar: arq schedules each job as its own asyncio
task, and tasks copy the context at creation, so concurrent orders in one
worker each see their own tracker. Code outside an active order (e.g. offline
scripts) finds no tracker and the hooks no-op.
"""

from __future__ import annotations

import contextvars
import logging
import os
from dataclasses import dataclass

import httpx

logger = logging.getLogger(__name__)

OPENROUTER_CREDITS_URL = "https://openrouter.ai/api/v1/credits"

# Tavily PAYG: $8 per 1000 credits → 0.8¢/credit. Both pipeline call sites use
# search_depth="advanced", which Tavily bills at 2 credits per query.
TAVILY_CENTS_PER_CREDIT = 0.8
TAVILY_ADVANCED_SEARCH_CREDITS = 2


@dataclass
class OrderCostTracker:
    """Accumulates measured spend for one order run."""

    tavily_credits: int = 0

    @property
    def search_cost_cents(self) -> int:
        return round(self.tavily_credits * TAVILY_CENTS_PER_CREDIT)


_current: contextvars.ContextVar[OrderCostTracker | None] = contextvars.ContextVar(
    "order_cost_tracker", default=None
)


def activate() -> tuple[OrderCostTracker, contextvars.Token]:
    """Install a fresh tracker for the current task; pair with `deactivate`."""
    tracker = OrderCostTracker()
    return tracker, _current.set(tracker)


def deactivate(token: contextvars.Token) -> None:
    _current.reset(token)


def add_tavily_credits(credits: int) -> None:
    """Record a billed Tavily query; no-op outside an active order run."""
    tracker = _current.get()
    if tracker is not None:
        tracker.tavily_credits += credits


async def fetch_openrouter_usage() -> float | None:
    """Lifetime account usage in USD from the OpenRouter credits API.

    Returns None whenever the number would be meaningless or unobtainable —
    gateway not set to openrouter, key missing, HTTP failure — so callers can
    persist NULL instead of a fabricated zero (fail loud in the data).
    """
    from quiz_shared.llm.factory import OPENROUTER, gateway

    if gateway() != OPENROUTER:
        return None
    api_key = os.getenv("OPENROUTER_API_KEY")
    if not api_key:
        return None
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            response = await client.get(
                OPENROUTER_CREDITS_URL,
                headers={"Authorization": f"Bearer {api_key}"},
            )
            response.raise_for_status()
            return float(response.json()["data"]["total_usage"])
    except Exception as exc:
        logger.warning("OpenRouter credits fetch failed: %r", exc)
        return None
