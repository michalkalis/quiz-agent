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

CATEGORIES: tuple[str, ...] = (
    "general",
    "adults",
    "kids",
    "wizarding-world",
    "superheroes",
    "disney",
    "football",
    "sports-mix",
)

DIFFICULTIES: tuple[str, ...] = ("easy", "medium", "hard")

# Common near-misses the model may emit → canonical taxonomy id.
_CATEGORY_ALIASES: dict[str, str] = {
    "children": "kids",
    "kid": "kids",
    "adult": "adults",
    "harry-potter": "wizarding-world",
    "harry potter": "wizarding-world",
    "wizarding world": "wizarding-world",
    "sport": "sports-mix",
    "sports": "sports-mix",
    "sports mix": "sports-mix",
    "soccer": "football",
    "marvel": "superheroes",
    "dc": "superheroes",
    "superhero": "superheroes",
}


def normalize_difficulty(value: object, default: str = "medium") -> str:
    """Coerce a model-emitted difficulty to easy|medium|hard (fail-safe)."""
    text = str(value or "").strip().lower()
    return text if text in DIFFICULTIES else default


def normalize_category(value: object, order_category: str | None = None) -> str:
    """Coerce a model-emitted category to the taxonomy (fail-safe).

    An explicit order category (e.g. a themed/custom-pack order like
    "entertainment") always wins, even off-taxonomy — those packs are played
    by ``pack_id``, not by the category filter, and the customer named the
    category. Without an order category the model classifies freely; unknown
    values fall back to "general" so the player filter never loses the
    question.
    """
    if order_category:
        return order_category.strip().lower()
    text = str(value or "").strip().lower()
    text = _CATEGORY_ALIASES.get(text, text)
    return text if text in CATEGORIES else "general"
