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
- #224 (TF test 2026-11-02): a customer-chosen level (custom pack) must be
  enforced on every question, since "hard" packs came out too easy. The mixed
  path (no level, every corpus run) must not change by a single byte.
"""

from __future__ import annotations

import os

import pytest
from app.generation.classification import (
    CATEGORIES,
    CATEGORY_DEFINITIONS,
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
    """#170 gate F1 (R1): the taxonomy is the app's six interest ids +
    entertainment. Near-misses and the retired audience/fandom ids must
    land in the nearest interest category, never in the fallback bucket."""
    assert normalize_category("Science") == "science-nature"
    assert normalize_category("geography") == "geography-world"
    assert normalize_category("Movies & Music") == "movies-music"
    assert normalize_category("food") == "food-everyday"
    assert normalize_category("soccer") == "sports"
    assert normalize_category("sports-mix") == "sports"
    assert normalize_category("Harry Potter") == "movies-music"
    assert normalize_category("disney") == "movies-music"


def test_unclassifiable_category_returns_none_never_general() -> None:
    """2026-11-21 category review: the old fail-safe stored `general`, an id no
    picker offers, so 791 approved questions were reachable only under "all
    categories". An off-taxonomy value must now come back as `None` (the stage
    drops it loudly), and `general` itself is no longer an acceptable answer.
    (Since #170 gate F1 "History" IS a taxonomy id, so it passes through.)"""
    assert normalize_category("History") == "history"
    assert normalize_category("Trivia") is None
    assert normalize_category(None) is None
    assert normalize_category("") is None
    assert normalize_category("general") is None
    assert normalize_category("kids") is None  # age is a filter, not a category


def test_everyday_is_not_food() -> None:
    """`food-everyday` now means food and drink only (founder 2026-11-21, shown
    as Jedlo a pitie / Food & Drink); 86 rows about cars, brands and household
    life had landed there. A bare "everyday" label must not be forced into it."""
    assert normalize_category("everyday") is None
    assert normalize_category("Food & Drink") == "food-everyday"
    assert normalize_category("Pop Culture") == "entertainment"


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


# --- #224: fixed level enforced, mixed path frozen ---------------------------

_PROMPTS_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "prompts")
# The default builder template and the prod generic path (`direct_v1`).
_TEMPLATES = [
    None,
    os.path.join(_PROMPTS_DIR, "question_generation_direct.md"),
]

# The exact text the mixed path rendered before #224. Every corpus run takes
# this path, and its 30/50/20 spread + honest-assessment wording are what the
# corpus difficulty filter is calibrated on, so a fixed-level change must not
# leak into it.
_MIXED_HEADER_BEFORE_224 = (
    "**Difficulty:** mixed — aim for roughly 30% easy / 50% medium / 20% hard "
    "across the batch\n"
)
_MIXED_GUIDANCE_BEFORE_224 = """\
## DIFFICULTY & CATEGORY (per question)

**`difficulty` — assess each question honestly** (never copy one value onto the
whole batch). Calibrate for a non-native-English adult player:
- `easy` — most players answer instantly (widely known fact, obvious deduction).
- `medium` — takes real thought or partial knowledge; a motivated player gets there.
- `hard` — only players with genuine knowledge of the area get it; still fair, never arcane.

**`category` — classify each question**"""
_MIXED_FIELD_BEFORE_224 = (
    '"difficulty": "easy | medium | hard — your honest assessment of THIS '
    'question (see DIFFICULTY & CATEGORY)"'
)


def _build_with(template, difficulty=None) -> str:
    builder = PromptBuilder(template_path=template) if template else PromptBuilder()
    return builder.build_prompt(count=3, difficulty=difficulty)


@pytest.mark.parametrize("template", _TEMPLATES)
def test_mixed_path_difficulty_text_is_byte_identical_to_before_224(
    template,
) -> None:
    prompt = _build_with(template)
    assert _MIXED_HEADER_BEFORE_224 in prompt
    assert _MIXED_GUIDANCE_BEFORE_224 in prompt
    assert _MIXED_FIELD_BEFORE_224 in prompt
    assert "must be" not in prompt.split("## DIFFICULTY & CATEGORY")[1].split(
        "**`category`"
    )[0]


@pytest.mark.parametrize("template", _TEMPLATES)
@pytest.mark.parametrize("level", ["easy", "medium", "hard"])
def test_fixed_level_is_enforced_on_every_question(template, level) -> None:
    """A chosen level is a requirement, not a hint: the header, the guidance and
    the schema line all demand it, and nothing tells the model to spread."""
    prompt = _build_with(template, difficulty=level)
    assert (
        f"**Difficulty:** {level} — every question in this batch must be {level}"
        in prompt
    )
    assert f"every question must be\n`{level}`." in prompt
    assert f"this order needs {level}" in prompt
    # The contradicting mixed-batch instructions are gone.
    assert "never copy one value onto the whole batch" not in prompt
    assert "30% easy / 50% medium / 20% hard" not in prompt


@pytest.mark.parametrize("level", ["easy", "medium", "hard"])
def test_fixed_level_uses_the_shared_rubric(level) -> None:
    """The level definitions are the same rubric the mixed path (and the
    corpus difficulty labels) use, so "hard" means the same thing in a custom
    pack as in the corpus filter."""
    fixed = _build(difficulty=level)
    for line in _MIXED_GUIDANCE_BEFORE_224.splitlines():
        if line.startswith("- `"):
            assert line in fixed


def test_no_order_category_instructs_taxonomy_classification() -> None:
    prompt = _build()
    for category in CATEGORIES:
        assert category in prompt
    assert "classify THIS question" in prompt


def test_classifier_prompt_offers_no_catch_all() -> None:
    """2026-11-21: the old guidance ended "When in doubt, use `general`" and the
    order header read "Categories: general", so the model filed hundreds of
    ordinary questions under an id no picker offers. The prompt must describe
    exactly the seven real ids and name no escape bucket."""
    prompt = _build()
    section = prompt[prompt.index("## DIFFICULTY & CATEGORY"):]
    assert "general" not in section.lower().replace("general knowledge", "")
    assert "when in doubt" not in prompt.lower()
    assert "**Categories:** general" not in prompt
    for category in CATEGORIES:
        assert f"- `{category}` — {CATEGORY_DEFINITIONS[category]}" in prompt
    # the confusable subjects are routed explicitly, food-everyday stays food
    flat = " ".join(section.split())
    assert "`food-everyday` is food and drink only" in flat
    for subject in ("Word origins", "Customs and holidays", "Brands:", "Everyday life:"):
        assert subject in flat


def test_structured_mcq_field_names_only_real_categories() -> None:
    """The MCQ path reads its category instruction from the tool schema, which
    still listed the pre-#39 ids with "use 'general' when nothing themed
    fits" — a second road into the invisible bucket."""
    from app.generation.advanced_generator import MCQQuestionItem

    description = MCQQuestionItem.model_fields["category"].description or ""
    assert "general" not in description
    for category in CATEGORIES:
        assert category in description


def test_explicit_order_category_is_pinned_in_schema_and_guidance() -> None:
    prompt = _build(categories=["entertainment"])
    assert '"category": "entertainment"' in prompt
    assert 'set `category` to\nexactly "entertainment"' in prompt
    assert "classify THIS question" not in prompt
