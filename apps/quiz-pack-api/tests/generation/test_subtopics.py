"""Approved subtopic taxonomy (#170 task 170.3, A1).

Why these tests matter:
- `subtopics.json` is the founder-approved coverage map (locked 5, gate F1
  2026-09-04 + round 2 2026-09-07). The coverage allocator will steer
  generation by its cells, so a category missing from it, or a name the DB
  column cannot hold (`questions.subtopic VARCHAR(64)`, D8), would surface
  weeks later as a fail-loud in a steered batch — or worse, as a silently
  uniform map. The file must match the taxonomy the code advertises.
- The loader must fail loud on an unknown category: the runtime never
  steers by a taxonomy that does not exist.
"""

from __future__ import annotations

import json

import pytest
from app.generation import subtopics as st
from app.generation.classification import CATEGORIES, FALLBACK_CATEGORY

MIN_PER_CATEGORY = 10
MAX_CHARS = 64


def _raw() -> dict:
    return json.loads(st.SUBTOPICS_PATH.read_text(encoding="utf-8"))


def test_file_matches_schema_and_covers_every_taxonomy_id() -> None:
    raw = _raw()
    assert list(raw) == ["en"], "one language block for now (SK/CS add theirs, #168)"
    by_cat = raw["en"]
    assert set(by_cat) == set(CATEGORIES), (
        "subtopics.json and CATEGORIES must name the same ids — a category "
        "without subtopics can never be steered, a subtopic block without a "
        "category id can never be persisted"
    )
    for category, subtopics in by_cat.items():
        assert isinstance(subtopics, list) and len(subtopics) >= MIN_PER_CATEGORY, (
            category
        )
        assert all(isinstance(s, str) and s.strip() for s in subtopics), category
        assert all(len(s) <= MAX_CHARS for s in subtopics), (
            f"{category}: >{MAX_CHARS} chars"
        )
        normalized = [" ".join(s.split()).lower() for s in subtopics]
        assert len(set(normalized)) == len(normalized), (
            f"{category}: duplicate subtopic"
        )


def test_fallback_category_has_no_subtopics() -> None:
    """`general` is the unclassified bucket, not a player filter — it must
    never get a coverage cell, or the allocator would steer towards junk."""
    assert FALLBACK_CATEGORY not in _raw()["en"]


def test_loader_is_cached_and_immutable() -> None:
    a = st.load_subtopics()
    b = st.load_subtopics()
    assert a is b
    assert isinstance(st.subtopics_for("history"), tuple)


def test_loader_fails_loud_on_unknown_category_or_language() -> None:
    with pytest.raises(KeyError, match="no subtopics for category 'kids'"):
        st.subtopics_for("kids")
    with pytest.raises(KeyError, match="language 'sk'"):
        st.subtopics_for("history", language="sk")


def test_round_two_additions_are_present() -> None:
    """Gate F1 round 2 (2026-09-07): the founder kept 59 of 60 everyday
    additions and dropped exactly one — the file must reflect that verdict."""
    geo = st.subtopics_for("geography-world")
    assert "Railways, metros and famous roads" in geo
    assert "Airports, airlines and airport codes" not in geo
    assert "Celebrity couples, feuds and scandals" in st.subtopics_for("entertainment")
    assert sum(len(st.subtopics_for(c)) for c in CATEGORIES) == 199
