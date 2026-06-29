"""#72 F-1 — TopicPool samples curated topics for the no-category path.

Why these scenarios:

The pool is what the no-category ("surprise me") path sources on once the
stopword set has (correctly) refused to search the literal word "general". These
tests pin the behavior the runtime depends on and the guarantees that keep the
military bias from creeping back via the data file itself:

- ``sample()`` returns the requested count, all distinct, all drawn from the
  pool — a pack never repeats a topic or invents one off-list.
- a smaller-than-count pool is capped, not padded or crashed (``random.sample``
  raises if count > population).
- a missing/garbled pool degrades to ``[]`` / ``None`` so SourcingStage keeps
  its broad-feed fallback rather than failing a run.
- ``merge_topics`` (the refresh tool's core) only appends genuinely-new topics,
  case-insensitively, preserving order — a refresh is an auditable append.
- the SHIPPED pool is non-trivial, has no duplicate concept, and contains no
  war/military/weapons topics — the curated list IS the anti-bias guarantee, so
  a careless edit that reintroduces "tanks of WW2" must fail a test.
"""

from __future__ import annotations

import json
from pathlib import Path

from app.sourcing.topic_pool import TopicPool, merge_topics


def _pool(tmp_path: Path, topics: list[str]) -> TopicPool:
    path = tmp_path / "topic_pool.json"
    path.write_text(json.dumps({"topics": topics}), encoding="utf-8")
    return TopicPool(path=path)


def test_sample_returns_distinct_topics_from_pool(tmp_path: Path) -> None:
    topics = [f"topic {i}" for i in range(20)]
    pool = _pool(tmp_path, topics)

    sampled = pool.sample(5)

    assert sampled is not None
    assert len(sampled) == 5
    assert len(set(sampled)) == 5  # no duplicate topic within one pack
    assert set(sampled) <= set(topics)  # never invents an off-list topic


def test_sample_caps_at_pool_size(tmp_path: Path) -> None:
    pool = _pool(tmp_path, ["only one", "only two"])

    sampled = pool.sample(5)

    assert sampled is not None
    assert sorted(sampled) == ["only one", "only two"]


def test_missing_file_degrades_to_none(tmp_path: Path) -> None:
    pool = TopicPool(path=tmp_path / "does_not_exist.json")

    assert pool.load() == []
    assert pool.sample() is None


def test_garbled_file_degrades_to_none(tmp_path: Path) -> None:
    path = tmp_path / "topic_pool.json"
    path.write_text("not json {", encoding="utf-8")

    assert TopicPool(path=path).sample() is None


def test_load_filters_blank_and_nonstring(tmp_path: Path) -> None:
    path = tmp_path / "topic_pool.json"
    path.write_text(
        json.dumps({"topics": ["  coral reefs  ", "", 42, "   "]}), encoding="utf-8"
    )

    assert TopicPool(path=path).load() == ["coral reefs"]


# --- merge_topics (the refresh tool's core) -------------------------------


def test_merge_appends_only_new_case_insensitively() -> None:
    existing = ["coral reefs", "jazz history"]
    proposed = ["Coral Reefs", "norse mythology", "JAZZ HISTORY", "the rings of saturn"]

    merged, added = merge_topics(existing, proposed)

    assert added == ["norse mythology", "the rings of saturn"]
    assert merged == [
        "coral reefs",
        "jazz history",
        "norse mythology",
        "the rings of saturn",
    ]


def test_merge_dedupes_within_proposed_batch() -> None:
    merged, added = merge_topics([], ["coral reefs", "Coral Reefs", "norse mythology"])

    assert added == ["coral reefs", "norse mythology"]
    assert merged == added


# --- the shipped pool is the anti-bias guarantee --------------------------


def test_shipped_pool_is_substantial_and_unique() -> None:
    topics = TopicPool().load()

    assert len(topics) >= 40
    lowered = [t.lower() for t in topics]
    assert len(set(lowered)) == len(lowered)  # no duplicate concept


def test_shipped_pool_has_no_military_or_generic_topics() -> None:
    """The pool exists to END the general→military bias; a curated list that
    smuggled war/weapons (or the generic words we strip) back in would defeat
    the whole fix. Fails loudly on a careless edit."""
    banned = (
        "war", "military", "weapon", "battle", "army", "soldier", "tank",
        "general knowledge", "trivia", "random facts",
    )
    blob = " | ".join(t.lower() for t in TopicPool().load())

    for term in banned:
        assert term not in blob, f"banned term in curated pool: {term!r}"
