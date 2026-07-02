"""#76 F-3b — recency-aware Tavily news sourcing, dormant by default.

Why these scenarios:

The entertainment category wants *fresh* facts (recent film/TV/music news), so
``WebSearchSource`` can ask Tavily for recent news via ``topic="news"`` +
``time_range="week"``. But this must never change today's behaviour unless a
deploy opts in — the default sourcing path feeds every existing order. These
tests pin the contract on both sides:

- ``test_news_mode_passes_recency_params``: when news mode is on, the recency
  params actually reach the Tavily ``search`` call (otherwise the flag is a
  silent no-op and the category never gets fresh facts).
- ``test_default_mode_omits_recency_params``: the default path stays
  byte-identical — NEITHER param is present. If a refactor leaked the params in
  by default, every general order would silently narrow to week-old news.
- ``test_env_flag_default_leaves_news_off``: the ``ENABLE_NEWS_SOURCING`` wiring
  in ``FactSourcer`` defaults off, so an unset env means the shipped behaviour.

No network: the Tavily client is replaced with an ``AsyncMock`` double, so a
real HTTP call would fail loudly.
"""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from app.sourcing.fact_sourcer import FactSourcer
from app.sourcing.web_search_source import WebSearchSource


def _mock_search_source(news_mode: bool) -> WebSearchSource:
    """A ``WebSearchSource`` whose Tavily client is a no-network double."""
    source = WebSearchSource(api_key="test-key", news_mode=news_mode)
    source.client = SimpleNamespace(search=AsyncMock(return_value={"results": []}))
    return source


@pytest.mark.asyncio
async def test_news_mode_passes_recency_params() -> None:
    source = _mock_search_source(news_mode=True)

    await source.get_facts(count=1, topics=["film"])

    source.client.search.assert_awaited_once()
    kwargs = source.client.search.await_args.kwargs
    assert kwargs["topic"] == "news"
    assert kwargs["time_range"] == "week"


@pytest.mark.asyncio
async def test_default_mode_omits_recency_params() -> None:
    source = _mock_search_source(news_mode=False)

    await source.get_facts(count=1, topics=["film"])

    source.client.search.assert_awaited_once()
    kwargs = source.client.search.await_args.kwargs
    assert "topic" not in kwargs
    assert "time_range" not in kwargs


def test_env_flag_default_leaves_news_off(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Unset flag → shipped behaviour: the web_search source is built with
    # news mode off.
    monkeypatch.setenv("TAVILY_API_KEY", "test-key")
    monkeypatch.delenv("ENABLE_NEWS_SOURCING", raising=False)

    sourcer = FactSourcer(
        enable_wikipedia=False,
        enable_opentdb=False,
        enable_web_search=True,
    )

    assert sourcer.sources["web_search"].news_mode is False
