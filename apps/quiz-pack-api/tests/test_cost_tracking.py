"""#95 — per-order cost tracker unit tests.

Why: the measured $/question from the first founder order is what validates
the €3.99 price point (Session 4 gate). These tests pin the two properties
the measurement depends on: per-order isolation (concurrent orders must not
pollute each other's Tavily counts) and fail-soft None (an unmeasurable LLM
cost must persist as NULL, never a fabricated number).
"""

from __future__ import annotations

import asyncio

import pytest

from app import cost_tracking


def test_add_is_noop_without_active_tracker() -> None:
    """Offline scripts / API requests outside an order run must not crash."""
    cost_tracking.add_tavily_credits(2)  # must not raise


def test_tracker_accumulates_and_converts_to_cents() -> None:
    tracker, token = cost_tracking.activate()
    try:
        for _ in range(3):
            cost_tracking.add_tavily_credits(
                cost_tracking.TAVILY_ADVANCED_SEARCH_CREDITS
            )
        assert tracker.tavily_credits == 6
        # 6 credits × 0.8¢ = 4.8¢ → 5¢ (rounded, not truncated).
        assert tracker.search_cost_cents == 5
    finally:
        cost_tracking.deactivate(token)
    # After deactivation new calls no longer land on this tracker.
    cost_tracking.add_tavily_credits(2)
    assert tracker.tavily_credits == 6


@pytest.mark.asyncio
async def test_concurrent_orders_do_not_share_trackers() -> None:
    """arq schedules each job as its own asyncio task; each task's tracker
    must only see its own order's search calls."""

    async def run_order(credits: int) -> int:
        tracker, token = cost_tracking.activate()
        try:
            await asyncio.sleep(0)  # interleave with the other task
            cost_tracking.add_tavily_credits(credits)
            await asyncio.sleep(0)
            return tracker.tavily_credits
        finally:
            cost_tracking.deactivate(token)

    counts = await asyncio.gather(run_order(2), run_order(10))
    assert counts == [2, 10]


@pytest.mark.asyncio
async def test_fetch_usage_none_when_gateway_direct(monkeypatch) -> None:
    """In direct mode the OpenRouter number is meaningless — must be None
    (persisted as NULL), not zero, so a missing measurement is visible."""
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    assert await cost_tracking.fetch_openrouter_usage() is None


@pytest.mark.asyncio
async def test_fetch_usage_none_without_api_key(monkeypatch) -> None:
    monkeypatch.setenv("LLM_GATEWAY", "openrouter")
    monkeypatch.delenv("OPENROUTER_API_KEY", raising=False)
    assert await cost_tracking.fetch_openrouter_usage() is None
