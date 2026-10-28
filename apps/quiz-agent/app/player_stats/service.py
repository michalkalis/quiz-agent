"""Compute a player's stat cards from their analytics events (#213).

Called per request (no cache: one call stays well under 200 ms at 10k events).
``start``/``end`` give the [start, end) window and ``fallback_tz`` the zone for
games with no timezone of their own, so the recap snapshots (213.3) reuse this
as is.
"""

from __future__ import annotations

from datetime import datetime

from sqlalchemy.ext.asyncio import AsyncSession

from . import cards, queries
from .config import THRESHOLDS as T


async def compute_player_stats(
    session: AsyncSession,
    subject_ids: list[str],
    *,
    start: datetime | None = None,
    end: datetime | None = None,
    fallback_tz: str = "UTC",
) -> dict:
    """``{"cards": [...], "first_recap_progress": {...}}`` for the given
    identities (the account plus its linked anonymous ids)."""
    args = (session, subject_ids, start, end)
    game_rows = await queries.fetch_games(*args)
    games = cards.build_games(game_rows, fallback_tz)
    dims = await queries.fetch_dims(*args)
    total = sum(d.answers for d in dims)
    days = cards.local_days(games)
    span = cards.span_days(games)

    thirds: list[tuple] = []
    if total >= T["improvement_min_answers"] and span >= T["improvement_min_days"]:
        thirds = await queries.fetch_thirds(*args)
    streak = await queries.fetch_best_streak(*args) if games else 0
    speed = await queries.fetch_speed(*args) if games else []

    return {
        "cards": [
            cards.totals_card(games, dims),
            *cards.category_cards(dims),
            cards.where_card(games),
            cards.when_card(games),
            cards.typical_card(games),
            cards.improvement_card(total, span, thirds),
            cards.streak_card(len(games), streak),
            cards.hard_card(dims),
            cards.mcq_open_card(dims),
            cards.speed_card(speed),
        ],
        "first_recap_progress": {
            "answers": total,
            "answers_target": T["first_recap_answers"],
            "days": days,
            "days_target": T["first_recap_days"],
        },
    }
