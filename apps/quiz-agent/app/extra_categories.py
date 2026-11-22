"""#242 — the catalog of free rotating extra categories (plan
issue-242-extra-categories-rotation.md, step 242.3).

Extra categories are served only to a session that asks for the key (the
isolation filter is ``EXTRA_CATEGORY_PREFIX``); this module decides which
keys the player is offered. The catalog is code on purpose: it changes by PR
(names go through the copy review). An entry is offered when the switch is on,
today (UTC) is inside its window, the language has a name for it and the
language holds at least ``MIN_QUESTIONS`` playable questions for the caller's
build channel (counted like family topics). An entry with no window is "not
scheduled" and never shown, so adding the code before the content exists is safe.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from datetime import UTC, date, datetime

from fastapi import HTTPException
from quiz_shared.models.question import EXTRA_CATEGORY_PREFIX

from . import app_switches
from .config import Settings

# Six rounds of ten without a repeat (plan, step 242.4).
MIN_QUESTIONS = 60
COUNTS_SECONDS = 300.0


@dataclass(frozen=True)
class ExtraCategory:
    key: str
    # A language without a name hides the category there.
    names: dict[str, str]
    # Inclusive, UTC. Neither set = not scheduled = never shown.
    starts: date | None = None
    until: date | None = None


CATALOG: tuple[ExtraCategory, ...] = (
    ExtraCategory(
        "extra-harry-potter",
        {"sk": "Harry Potter", "cs": "Harry Potter", "en": "Harry Potter"},
        starts=date(2026, 11, 22),
        until=date(2026, 12, 22),
    ),
    ExtraCategory(
        "extra-superheroes",
        {"sk": "Superhrdinovia", "cs": "Superhrdinové", "en": "Superheroes"},
        starts=date(2026, 11, 22),
        until=date(2026, 12, 22),
    ),
    ExtraCategory(
        "extra-techno",
        {
            "sk": "Techno a klubová scéna",
            "cs": "Techno a klubová scéna",
            "en": "Techno & Club Culture",
        },
        # Joins at the first monthly swap (founder: three at a time).
        starts=date(2026, 12, 23),
        until=date(2027, 1, 22),
    ),
    ExtraCategory(
        "extra-animation",
        {
            "sk": "Rozprávky a animáky",
            "cs": "Pohádky a animáky",
            "en": "Cartoons & Fairy Tales",
        },
        starts=date(2026, 11, 22),
        until=date(2026, 12, 22),
    ),
)
KEYS = tuple(c.key for c in CATALOG)

_counts: dict[tuple[str, str | None], tuple[float, dict]] = {}


def reset_cache() -> None:
    _counts.clear()


def utc_today() -> date:
    return datetime.now(UTC).date()


def in_window(entry: ExtraCategory, today: date) -> bool:
    if entry.starts is None and entry.until is None:
        return False
    return (entry.starts is None or entry.starts <= today) and (
        entry.until is None or today <= entry.until
    )


def offered(language: str, today: date) -> list[ExtraCategory]:
    """Catalog entries inside their window with a name in ``language``."""
    return [c for c in CATALOG if language in c.names and in_window(c, today)]


def catalog_entries(language: str, counts: dict[tuple, int], today: date) -> list[dict]:
    """Ordered ``{key, name, until}`` of the offered entries that have
    ``MIN_QUESTIONS`` playable questions. ``counts`` = per ``(category,)``."""
    return [
        {
            "key": c.key,
            "name": c.names[language],
            "until": c.until.isoformat() if c.until else None,
        }
        for c in offered(language, today)
        if counts.get((c.key,), 0) >= MIN_QUESTIONS
    ]


async def extra_categories_on(settings: Settings, sessionmaker) -> bool:
    return await app_switches.is_on(settings, sessionmaker, "extra_categories_enabled")


async def extra_counts(retriever, language: str, channel: str | None) -> dict:
    """Playable questions per catalog key for one language and build channel,
    cached ~5 min (shared by everyone, independent of the player's history)."""
    cache_key = (language, channel)
    hit = _counts.get(cache_key)
    if hit is not None and hit[0] > time.monotonic():
        return hit[1]
    counts = await retriever.extra_category_counts(language, channel, KEYS)
    _counts[cache_key] = (time.monotonic() + COUNTS_SECONDS, counts)
    return counts


def only_extra(categories) -> bool:
    """A request that asks for extra categories and nothing permanent."""
    return bool(categories) and all(
        c.startswith(EXTRA_CATEGORY_PREFIX) for c in categories
    )


def _error(status: int, code: str, message: str) -> HTTPException:
    return HTTPException(status_code=status, detail={"code": code, "message": message})


async def check_extra_request(
    categories, language: str, settings: Settings, sessionmaker, today=None
) -> None:
    """400 ``extra_category_invalid`` when a requested extra key is not offered
    right now (rotated out, never scheduled, no name in this language, or the
    switch is off). Permanent keys are not looked at. The playable-question
    count is not checked here: a thin category ends in ``/start`` instead."""
    asked = [c for c in categories or [] if c.startswith(EXTRA_CATEGORY_PREFIX)]
    if not asked:
        return
    live = {c.key for c in offered(language, today or utc_today())}
    if not await extra_categories_on(settings, sessionmaker) or not set(asked) <= live:
        raise _error(
            400, "extra_category_invalid", "This category is not available now"
        )


def exhausted_error() -> HTTPException:
    """409 for an extra-only session with nothing unplayed left."""
    return _error(
        409,
        "extra_category_exhausted",
        "Every question in this category has been played",
    )
