"""Unit tests for the fact sources (#42 task 42.28).

Why these scenarios:

- `test_category_map_has_at_least_20_entries` / `test_category_map_*`: the
  OpenTriviaDB map was widened 10 → 24 so prompt-derived topics (film,
  mythology, politics, …) resolve to a real opentdb category instead of
  falling back to General. These guard the map against silently shrinking and
  against a rename — `_map_topics_to_categories` matches the names verbatim, so
  renaming a pre-existing entry would break topic matching with no error.
- `test_get_facts_skips_topic_agnostic_feeds_when_topics_present`: the
  Wikipedia "Did you know" + featured feeds are topic-agnostic (whatever is on
  the main page today) and were the main source of off-prompt drift. With
  topics, only the topic search may run.
- `test_get_facts_uses_broad_feeds_when_no_topics`: back-compat — un-themed
  orders still rely on the broad feeds, so they must run when no topics.
"""

from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

from app.sourcing.opentriviadb_source import CATEGORY_MAP
from app.sourcing.wikipedia_source import WikipediaSource


def test_category_map_has_at_least_20_entries() -> None:
    assert len(CATEGORY_MAP) >= 20


def test_category_map_names_are_unique() -> None:
    # Each topic name must map to exactly one category. A duplicate name (a
    # likely copy-paste slip when adding entries) makes
    # `_map_topics_to_categories` return two ids for one topic match — and
    # since topic matching is by name, the second mapping is dead weight.
    # (Duplicate *keys* can't be asserted post-construction — the dict literal
    # silently keeps the last — so the checkable invariant is unique values.)
    assert len(set(CATEGORY_MAP.values())) == len(CATEGORY_MAP)


def test_category_map_preserves_pre_existing_names() -> None:
    # `_map_topics_to_categories` matches these verbatim (lowercased); a rename
    # breaks topic matching with no error, so pin the original names.
    for name in ("General", "Science", "Technology", "Geography", "History",
                 "Art", "Nature", "Music", "Sports", "Entertainment"):
        assert name in CATEGORY_MAP.values()


@pytest.mark.asyncio
async def test_get_facts_skips_topic_agnostic_feeds_when_topics_present() -> None:
    source = WikipediaSource()
    source._get_did_you_know = AsyncMock(return_value=[])
    source._get_featured_article_facts = AsyncMock(return_value=[])
    source._search_topic_facts = AsyncMock(return_value=[])

    await source.get_facts(count=10, topics=["volcanoes"])

    source._get_did_you_know.assert_not_awaited()
    source._get_featured_article_facts.assert_not_awaited()
    source._search_topic_facts.assert_awaited_once()


@pytest.mark.asyncio
async def test_get_facts_uses_broad_feeds_when_no_topics() -> None:
    source = WikipediaSource()
    source._get_did_you_know = AsyncMock(return_value=[])
    source._get_featured_article_facts = AsyncMock(return_value=[])
    source._search_topic_facts = AsyncMock(return_value=[])

    await source.get_facts(count=10, topics=None)

    source._get_did_you_know.assert_awaited()
    source._get_featured_article_facts.assert_awaited()
    source._search_topic_facts.assert_not_awaited()
