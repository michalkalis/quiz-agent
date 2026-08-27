"""Per-question difficulty/category generation (2026-07-27 live-run F-e).

Why these scenarios:

- The 2026-07-27 live run wrote 164 questions that were ALL
  `difficulty=medium` / `category=general` because the prompts told the
  model to echo the order-level defaults. The normalizers + prompt-builder
  instructions below are the fix; if either regresses, future runs silently
  ship an unclassified corpus again — the player-facing difficulty/category
  filters (iOS `Config.categoryOptions`) would have nothing real to filter.
- Normalization must be fail-safe: an off-vocabulary model value must never
  reach Postgres (the retriever matches these strings exactly).
- An explicit order category (themed/custom pack) must always win — the
  customer named it, and those packs play by `pack_id`, so the model gets
  no classification freedom there.
"""

from __future__ import annotations

from app.generation.classification import (
    CATEGORIES,
    normalize_category,
    normalize_difficulty,
)
from app.generation.prompt_builder import PromptBuilder


# --- normalize_difficulty ---------------------------------------------------


def test_valid_difficulties_pass_through() -> None:
    for value in ("easy", "medium", "hard"):
        assert normalize_difficulty(value) == value


def test_difficulty_is_case_and_whitespace_insensitive() -> None:
    assert normalize_difficulty(" Hard ") == "hard"


def test_junk_difficulty_falls_back_to_default() -> None:
    assert normalize_difficulty("expert") == "medium"
    assert normalize_difficulty(None) == "medium"
    assert normalize_difficulty("", default="easy") == "easy"


# --- normalize_category -----------------------------------------------------


def test_taxonomy_categories_pass_through() -> None:
    for value in CATEGORIES:
        assert normalize_category(value) == value


def test_category_aliases_map_to_taxonomy() -> None:
    assert normalize_category("children") == "kids"
    assert normalize_category("Harry Potter") == "wizarding-world"
    assert normalize_category("sports") == "sports-mix"
    assert normalize_category("soccer") == "football"


def test_junk_category_falls_back_to_general() -> None:
    # A subject ("History") is a topic, not a category — the player filter
    # would never match it, so it must land in the safe default.
    assert normalize_category("History") == "general"
    assert normalize_category(None) == "general"


def test_explicit_order_category_always_wins() -> None:
    # Themed/custom-pack orders: the customer named the category, even
    # off-taxonomy (e.g. a one-off "cycling" pack, played by pack_id).
    assert normalize_category("general", order_category="cycling") == "cycling"
    assert normalize_category("adults", order_category="Kids") == "kids"


def test_entertainment_is_a_first_class_taxonomy_id() -> None:
    """#167 (D7): entertainment has had its own generation prompt since #76 but
    was NOT in `CATEGORIES` — so a model-classified entertainment question fell
    through the unknown branch to "general" and became invisible to the player's
    entertainment filter, the one place those questions are meant to surface.

    Asserted on the no-order-category path on purpose: with an explicit order
    category the value passes through regardless (the test above), so only this
    call can distinguish "in the taxonomy" from "the customer named it".
    """
    assert normalize_category("entertainment") == "entertainment"


# --- prompt builder: per-question instructions ------------------------------


def _build(categories=None, difficulty=None) -> str:
    return PromptBuilder().build_prompt(
        count=3, difficulty=difficulty, categories=categories
    )


def test_no_order_difficulty_renders_mixed_spread_header() -> None:
    prompt = _build()
    assert "mixed — aim for roughly 30% easy / 50% medium / 20% hard" in prompt
    # The JSON schema line instructs assessment instead of echoing a value.
    assert "your honest assessment of THIS question" in prompt


def test_explicit_order_difficulty_keeps_target_but_still_assesses() -> None:
    prompt = _build(difficulty="hard")
    assert "**Difficulty:** hard" in prompt
    assert "your honest assessment of THIS question" in prompt


def test_no_order_category_instructs_taxonomy_classification() -> None:
    prompt = _build()
    for category in CATEGORIES:
        assert category in prompt
    assert "classify THIS question" in prompt


def test_explicit_order_category_is_pinned_in_schema_and_guidance() -> None:
    prompt = _build(categories=["entertainment"])
    assert '"category": "entertainment"' in prompt
    assert 'set `category` to\nexactly "entertainment"' in prompt
    assert "classify THIS question" not in prompt
