"""Per-question difficulty + category classification (2026-07-27 live-run F-e).

The generation LLM now assesses ``difficulty`` and ``category`` per question
instead of echoing the order-level defaults ("medium"/"general" on every row
of the 2026-07-27 run). This module is the single source of truth for the
allowed values and the fail-safe normalizers `GenerationStage` applies to
whatever the model emitted.

``CATEGORIES`` mirrors the player-facing filter taxonomy in the iOS app
(`Config.categoryOptions` in apps/ios-app/.../Utilities/Config.swift) — the
retriever filters `question.category` against exactly these ids, so an
off-taxonomy value would make a question invisible to that filter.
"""

from __future__ import annotations

# #170 gate F1 (founder 2026-09-04, R1): the generation taxonomy now equals
# the app's interest taxonomy (`CATEGORY_TAXONOMY` in quiz-agent admin.py,
# PR #39) plus `entertainment` (#167). The old audience/fandom ids (general,
# adults, kids, wizarding-world, superheroes, disney, football, sports-mix)
# are gone: age is the separate `age_appropriate` axis, fandom is pack
# material (played by pack_id, never by this filter), and the prod corpus has
# zero live rows under them. Until then a model-emitted "history" collapsed
# to "general" and every direct run wrote rows the player filter never shows.
CATEGORIES: tuple[str, ...] = (
    "science-nature",
    "history",
    "geography-world",
    "movies-music",
    "sports",
    "food-everyday",
    "entertainment",
)

# What each id holds, as the generation prompt describes it to the model
# (founder 2026-11-21: display names Zemepis / Jedlo a pitie / Popkultúra,
# ids unchanged). There is deliberately no catch-all: until 2026-11-21 the
# prompt offered "when in doubt, use general" and the normalizer stored
# `general`, which no picker offers, so 791 approved questions were reachable
# only under "all categories".
CATEGORY_DEFINITIONS: dict[str, str] = {
    "science-nature": (
        "Science & Nature: physics, chemistry, biology, the human body and "
        "medicine, animals and plants, space, weather, maths, technology "
        "(inventions, gadgets, the internet, how everyday things work), and "
        "the science behind food (why milk boils over, why chili burns)"
    ),
    "history": (
        "History: past events, eras, rulers, wars, famous people of the past, "
        "and where inventions, objects, customs and words came from"
    ),
    "geography-world": (
        "Geography: countries, cities, landmarks, rivers, mountains, flags, "
        "languages, peoples, and how life, customs and holidays are kept "
        "around the world today"
    ),
    "movies-music": (
        "Movies & Music: films, television series, actors, directors, music, "
        "musicians, songs, soundtracks"
    ),
    "sports": "Sports: every sport, athletes, clubs, competitions, records, rules",
    "food-everyday": (
        "Food & Drink: food and drink only (dishes, ingredients, cooking, "
        "drinks, restaurants and bars, food brands, food customs and food "
        "history)"
    ),
    "entertainment": (
        "Pop Culture: celebrities, video games, internet culture and social "
        "media, books and comics, toys, fashion, brands and advertising, "
        "recent entertainment news"
    ),
}

DIFFICULTIES: tuple[str, ...] = ("easy", "medium", "hard")

# Common near-misses the model may emit → canonical taxonomy id. Old taxonomy
# ids map to their nearest interest category so a prompt or fixture still
# carrying them cannot silently produce filter-invisible rows.
_CATEGORY_ALIASES: dict[str, str] = {
    "science": "science-nature",
    "nature": "science-nature",
    "science & nature": "science-nature",
    "science and nature": "science-nature",
    "technology": "science-nature",
    "geography": "geography-world",
    "world": "geography-world",
    "geography & world": "geography-world",
    "geography and world": "geography-world",
    "movies": "movies-music",
    "music": "movies-music",
    "film": "movies-music",
    "movies & music": "movies-music",
    "movies and music": "movies-music",
    "food": "food-everyday",
    "drink": "food-everyday",
    "food & drink": "food-everyday",
    "food and drink": "food-everyday",
    # the id's former display name; bare "everyday" is NOT food (2026-11-21)
    "food & everyday": "food-everyday",
    "food and everyday": "food-everyday",
    "pop culture": "entertainment",
    "pop-culture": "entertainment",
    "sport": "sports",
    "sports mix": "sports",
    "sports-mix": "sports",
    "soccer": "sports",
    "football": "sports",
    # fandom ids from the pre-#39 taxonomy → the interest category they sit in
    "wizarding-world": "movies-music",
    "harry-potter": "movies-music",
    "harry potter": "movies-music",
    "wizarding world": "movies-music",
    "superheroes": "movies-music",
    "superhero": "movies-music",
    "marvel": "movies-music",
    "dc": "movies-music",
    "disney": "movies-music",
}


def normalize_difficulty(value: object, default: str = "medium") -> str:
    """Coerce a model-emitted difficulty to easy|medium|hard (fail-safe)."""
    text = str(value or "").strip().lower()
    return text if text in DIFFICULTIES else default


def normalize_category(value: object, order_category: str | None = None) -> str | None:
    """Coerce a model-emitted category to the taxonomy, or ``None``.

    An explicit order category (e.g. a themed/custom-pack order like
    "entertainment") always wins, even off-taxonomy — those packs are played
    by ``pack_id``, not by the category filter, and the customer named the
    category. Without an order category the model classifies freely; a value
    that is neither a taxonomy id nor a known alias returns ``None`` and the
    caller drops the question loudly. There is no catch-all bucket: a stored
    off-picker category makes the question unreachable from every category
    filter (the 2026-11-21 `general` finding).
    """
    if order_category:
        return order_category.strip().lower()
    text = str(value or "").strip().lower()
    text = _CATEGORY_ALIASES.get(text, text)
    return text if text in CATEGORIES else None
