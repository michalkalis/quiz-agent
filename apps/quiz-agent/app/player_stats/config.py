"""Every threshold of the stat cards in one place (#213).

Changing a number here is a server deploy, no app build. Mirrors the card table
in ``docs/research/player-recap-wrapped-2026-10-27.md``.
"""

from __future__ import annotations

THRESHOLDS: dict[str, int] = {
    # category cards: need this many categories with this many answers each
    "category_min_categories": 3,
    "category_min_answers": 10,
    # best category is a "standout" only when it leads the runner-up by this
    # many percentage points, otherwise the player is "versatile"
    "standout_lead_points": 10,
    "where_min_games": 5,
    "when_min_games": 5,
    "when_min_days": 3,
    "typical_min_games": 5,
    "improvement_min_answers": 150,
    "improvement_min_days": 21,
    # accuracy change (points) below which the player "holds form"
    "improvement_steady_points": 3,
    "streak_min_games": 1,
    "hard_min_answers": 10,
    "mcq_open_min_each": 10,
    # accuracy gap (points) below which MCQ and open answers are "even"
    "mcq_open_even_points": 5,
    "speed_min_categories": 2,
    "speed_min_answers": 10,
    # the first recap unlocks at this much play
    "first_recap_answers": 60,
    "first_recap_days": 3,
    # a game left open (paused, forgotten) must not inflate play time
    "max_game_minutes": 120,
}

# Local hour (inclusive start) -> part of day; night wraps midnight.
PARTS_OF_DAY: tuple[tuple[str, int, int], ...] = (
    ("morning", 5, 12),
    ("afternoon", 12, 18),
    ("evening", 18, 23),
)

# quiz_context.audio_route -> where card group; anything else is "other".
AUDIO_ROUTE_GROUPS: dict[str, str] = {
    "carplay": "car",
    "bluetooth": "bluetooth",
    "speaker": "speaker",
    "headphones": "headphones",
}

# question_type of a multiple-choice question; every other type is "open".
MCQ_TYPE = "text_multichoice"
HARD_DIFFICULTY = "hard"
