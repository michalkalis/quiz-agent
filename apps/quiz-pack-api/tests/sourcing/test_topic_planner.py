"""#72 F-1 — TopicPlanner proposes diverse concrete topics to refresh the pool.

Why these scenarios:

The planner is the offline engine behind the curated topic pool (the no-category
path samples that pool at runtime, with no LLM call). Run by
scripts/refresh_topic_pool.py, it must hand back a *spread* of concrete topics
that explicitly avoids the "general"/"knowledge"/military dead end. These tests
pin:

- `test_unavailable_returns_none` / `test_client_exception_returns_none`: the
  fail-safe contract (mirrors ``OpenTriviaFactRewriter``/``AnswerNormalizer``).
  A dead model must degrade to ``None`` so a pool-refresh run degrades cleanly
  (reports "no topics", leaves the pool unchanged) instead of crashing.
- `test_proposes_parsed_topics`: the happy path actually returns the model's
  list, so the refresh tool has concrete topics to merge into the pool.
- `test_parse_*`: the parser is the only thing standing between a chatty/loose
  model and junk Tavily queries — it must tolerate fences and a ``{"topics":…}``
  wrapper, reject non-lists, dedupe case-insensitively, drop over-long/non-string
  entries, and cap the count so the model can't inflate web-search volume.

No network: the client is replaced with a ``SimpleNamespace`` double, so a real
OpenAI/OpenRouter call would fail loudly.
"""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from app.sourcing.topic_planner import TopicPlanner


def _fake_client(content: str) -> SimpleNamespace:
    """Minimal stand-in for the lazy ``openai_client`` the planner builds."""
    resp = SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(content=content))]
    )
    return SimpleNamespace(
        chat=SimpleNamespace(
            completions=SimpleNamespace(create=AsyncMock(return_value=resp))
        )
    )


# --- fail-safe contract (no network) --------------------------------------


@pytest.mark.asyncio
async def test_unavailable_returns_none(monkeypatch: pytest.MonkeyPatch) -> None:
    """No key + direct gateway → planner is unreachable → None (fall back)."""
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("LLM_GATEWAY", raising=False)  # default 'direct'

    assert await TopicPlanner().propose() is None


@pytest.mark.asyncio
async def test_client_exception_returns_none(monkeypatch: pytest.MonkeyPatch) -> None:
    """A raising model call must degrade to None, never propagate, so a
    transient API blip can't abort the whole generation run."""
    monkeypatch.setenv("OPENAI_API_KEY", "test-key")
    planner = TopicPlanner()
    planner._client = SimpleNamespace(
        chat=SimpleNamespace(
            completions=SimpleNamespace(
                create=AsyncMock(side_effect=RuntimeError("boom"))
            )
        )
    )

    assert await planner.propose() is None


# --- happy path -----------------------------------------------------------


@pytest.mark.asyncio
async def test_proposes_parsed_topics(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OPENAI_API_KEY", "test-key")
    planner = TopicPlanner(topic_count=3)
    planner._client = _fake_client(
        '["deep-sea bioluminescence", "the history of coffee", "volcanic islands"]'
    )

    assert await planner.propose() == [
        "deep-sea bioluminescence",
        "the history of coffee",
        "volcanic islands",
    ]


# --- parser (the junk-query firewall) -------------------------------------


def test_parse_strips_code_fence() -> None:
    fenced = '```json\n["jazz history", "coral reefs"]\n```'
    assert TopicPlanner()._parse(fenced) == ["jazz history", "coral reefs"]


def test_parse_handles_topics_object_wrapper() -> None:
    wrapped = '{"topics": ["roman roads", "north sea storms"]}'
    assert TopicPlanner()._parse(wrapped) == ["roman roads", "north sea storms"]


def test_parse_dedupes_case_insensitively_and_caps() -> None:
    """Duplicates would make sources search the same concept twice (re-introducing
    near-duplicate facts); an over-long list would inflate Tavily volume."""
    planner = TopicPlanner(topic_count=2)
    raw = '["Jazz History", "jazz history", "coral reefs", "alpine flora"]'
    # "jazz history" deduped against "Jazz History"; capped at 2.
    assert planner._parse(raw) == ["Jazz History", "coral reefs"]


def test_parse_drops_overlong_and_nonstring_entries() -> None:
    planner = TopicPlanner(topic_count=5)
    long_topic = "x" * 61  # > _MAX_TOPIC_LEN: a sentence, not a topic
    raw = f'["coral reefs", 42, "", "{long_topic}", "alpine flora"]'
    assert planner._parse(raw) == ["coral reefs", "alpine flora"]


def test_parse_rejects_non_list() -> None:
    assert TopicPlanner()._parse('"just a string"') is None
    assert TopicPlanner()._parse("not json at all") is None


def test_parse_empty_list_returns_none() -> None:
    """An empty/all-filtered result must be None so the caller falls back
    rather than passing an empty topic list to the sources."""
    assert TopicPlanner()._parse("[]") is None
    assert TopicPlanner()._parse('[123, ""]') is None
