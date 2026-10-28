"""Player type of a recap (#213.3): fixed rules over the window's cards, the
first match wins. Pure; the keys are plain strings the app maps to a title."""

from __future__ import annotations

from .config import PLAYER_TYPE_RULES as R


def _share(count: int, total: int) -> float:
    return 100 * count / total if total else 0.0


def player_type(cards: dict[str, dict], latency: tuple[int, float]) -> str:
    """``cards`` by kind (locked cards have empty data and never match);
    ``latency`` = (measured answers, median ms) over the whole window."""
    when = cards.get("when", {})
    if when.get("state") == "unlocked":
        d = when["data"]
        night = d.get("breakdown", {}).get("night", 0)
        if _share(night, d["games"]) >= R["night_owl_share"]:
            return "night_owl"
    where = cards.get("where", {})
    if where.get("state") == "unlocked":
        d = where["data"]
        if _share(d["breakdown"].get("car", 0), d["games"]) >= R["road_tripper_share"]:
            return "road_tripper"
    measured, median_ms = latency
    if measured >= R["speedster_min_measured"] and median_ms < R["speedster_median_ms"]:
        return "speedster"
    best = cards.get("best_category", {})
    if best.get("state") == "unlocked":
        # unlocked = at least 3 categories with enough answers
        return "specialist" if best["data"]["standout"] else "all_rounder"
    return "explorer"
