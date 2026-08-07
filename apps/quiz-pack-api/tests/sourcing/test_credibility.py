"""Unit tests for source credibility classification (#153 Phase 0.3).

Founder complaint: sdbif.org listicle and youtube.com links served as quiz
sources. These tests pin the domain classification `WebSearchSource` stamps
onto every `Fact`, plus the ranking/starvation-guard rules that consume it:

- `test_classify_credibility_*`: the allowlist/denylist/listicle-heuristic
  contract itself, including the exact sdbif.org slug from the complaint and
  a youtube.com link, so a regression in the classifier is caught directly
  rather than only downstream.
- `test_top_by_surprise_ranks_credibility_before_surprise`: credibility must
  lead the ranking (not just surprise) — a "high" fact with a low surprise
  score must still outrank a "low" fact with a high one.
- `test_drop_low_credibility_starved_*`: the founder-facing behavior — a
  low-credibility fact is dropped once its topic already has enough
  trustworthy material, but a thin topic keeps it (starvation guard) rather
  than being left short.
- `test_gather_facts_stamps_wikipedia_high_opentdb_medium`: the spec's other
  half — Wikipedia is stamped "high" and OpenTriviaDB stays "medium", done in
  `FactSourcer.gather_facts` rather than the source modules themselves.
"""

from __future__ import annotations

import pytest

from app.sourcing.fact_sourcer import FactSourcer
from app.sourcing.models import Fact, FactBatch
from app.sourcing.web_search_source import classify_credibility


def test_classify_credibility_high_for_reputable_domains() -> None:
    assert classify_credibility("https://en.wikipedia.org/wiki/Blue_whale") == "high"
    assert classify_credibility("https://www.reuters.com/world/") == "high"
    assert classify_credibility("https://www.nasa.gov/mission") == "high"


def test_classify_credibility_high_for_gov_edu_ac_uk_suffixes() -> None:
    assert classify_credibility("https://www.noaa.gov/story") == "high"
    assert classify_credibility("https://www.some-university.edu/research") == "high"
    assert classify_credibility("https://www.example.ac.uk/page") == "high"


def test_classify_credibility_low_for_youtube() -> None:
    # The founder complaint explicitly named youtube.com as a served source.
    assert classify_credibility("https://www.youtube.com/watch?v=abc123") == "low"
    assert classify_credibility("https://youtu.be/abc123") == "low"


def test_classify_credibility_low_for_sdbif_listicle_slug() -> None:
    # The exact sdbif.org example from the founder complaint.
    url = "https://sdbif.org/72-amazing-human-brain-facts-based-on-the-latest-science/"
    assert classify_credibility(url) == "low"


def test_classify_credibility_low_for_pinterest_buzzfeed_ranker() -> None:
    assert classify_credibility("https://www.pinterest.com/pin/123") == "low"
    assert classify_credibility("https://www.buzzfeed.com/list/123") == "low"
    assert classify_credibility("https://www.ranker.com/list/123") == "low"


def test_classify_credibility_medium_for_unclassified_non_listicle_domain() -> None:
    # An unknown domain with no listicle slug is neither trusted nor demoted.
    assert classify_credibility("https://www.some-random-blog.com/about") == "medium"


def test_classify_credibility_unknown_url_defaults_medium() -> None:
    assert classify_credibility("") == "medium"


# --- ranking: credibility leads, surprise breaks ties ----------------------


def test_top_by_surprise_ranks_credibility_before_surprise() -> None:
    """A "high" fact must outrank a "low" fact even with a lower surprise
    score — credibility now leads `top_by_surprise`'s ranking (#153 Phase
    0.3), not just the free surprise heuristic."""
    boring_but_trusted = Fact(text="Plain fact.", credibility="high", surprise_rating=2.0)
    exciting_but_untrusted = Fact(
        text="Wild claim!", credibility="low", surprise_rating=9.0
    )
    batch = FactBatch(facts=[exciting_but_untrusted, boring_but_trusted])

    top = batch.top_by_surprise(2)

    assert top[0] is boring_but_trusted
    assert top[1] is exciting_but_untrusted


def test_top_by_surprise_breaks_ties_within_tier_by_surprise() -> None:
    """Within one credibility tier, the pre-existing surprise ordering still
    applies — credibility only adds a coarser sort key in front of it."""
    high_dull = Fact(text="Dull.", credibility="high", surprise_rating=3.0)
    high_exciting = Fact(text="Exciting!", credibility="high", surprise_rating=8.0)
    batch = FactBatch(facts=[high_dull, high_exciting])

    top = batch.top_by_surprise(2)

    assert top == [high_exciting, high_dull]


# --- starvation-guarded low-credibility drop --------------------------------


def test_drop_low_credibility_starved_drops_when_topic_has_enough_trustworthy() -> None:
    topic = "Volcanoes"
    trustworthy = [
        Fact(text=f"Trustworthy {i}", topic=topic, credibility="medium") for i in range(3)
    ]
    low = Fact(text="Listicle claim", topic=topic, credibility="low")
    batch = FactBatch(facts=[*trustworthy, low])

    filtered, dropped = batch.drop_low_credibility_starved()

    assert dropped == 1
    assert low not in filtered.facts
    assert len(filtered.facts) == 3


def test_drop_low_credibility_starved_keeps_low_fact_when_topic_is_thin() -> None:
    """Starvation guard: a topic with < 3 medium/high facts keeps its
    low-credibility fact rather than being left with even fewer sourced
    facts."""
    topic = "Obscure Topic"
    trustworthy = [Fact(text="Only one", topic=topic, credibility="medium")]
    low = Fact(text="Listicle claim", topic=topic, credibility="low")
    batch = FactBatch(facts=[*trustworthy, low])

    filtered, dropped = batch.drop_low_credibility_starved()

    assert dropped == 0
    assert low in filtered.facts
    assert len(filtered.facts) == 2


def test_drop_low_credibility_starved_is_per_topic() -> None:
    """A thin topic's low fact survives even while a well-sourced topic's low
    fact next to it is dropped — the guard is per-topic, not batch-wide."""
    rich_topic_facts = [
        Fact(text=f"Rich {i}", topic="Rich Topic", credibility="medium") for i in range(3)
    ]
    rich_low = Fact(text="Rich listicle", topic="Rich Topic", credibility="low")
    thin_low = Fact(text="Thin listicle", topic="Thin Topic", credibility="low")
    batch = FactBatch(facts=[*rich_topic_facts, rich_low, thin_low])

    filtered, dropped = batch.drop_low_credibility_starved()

    assert dropped == 1
    assert rich_low not in filtered.facts
    assert thin_low in filtered.facts


# --- FactSourcer stamps per-source credibility ------------------------------


class _StubSource:
    def __init__(self, facts: list[Fact]) -> None:
        self._facts = facts

    async def get_facts(self, count: int = 10, topics: list[str] | None = None) -> list[Fact]:
        return self._facts


@pytest.mark.asyncio
async def test_gather_facts_stamps_wikipedia_high_opentdb_medium() -> None:
    """Wikipedia is a high-credibility source; OpenTriviaDB's "medium" is
    already the `Fact` default and must stay untouched (#153 Phase 0.3)."""
    sourcer = FactSourcer(enable_wikipedia=False, enable_opentdb=False, enable_web_search=False)
    sourcer.sources = {
        "wikipedia": _StubSource([Fact(text="From wiki", source_name="wikipedia")]),
        "opentdb": _StubSource([Fact(text="From opentdb", source_name="opentdb")]),
    }

    batch = await sourcer.gather_facts(count=10)

    by_source = {f.source_name: f for f in batch.facts}
    assert by_source["wikipedia"].credibility == "high"
    assert by_source["opentdb"].credibility == "medium"
