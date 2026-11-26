"""How many extra questions a finished daily challenge earns (#248.5).

Founder 2026-11-26 (option B): everyone who finishes gets the base reward; a
strong score earns a bonus on top. Never less than the base, so a weak score
is not punished. The phone shows and speaks the number the server sends, so
the amounts change here without a new app build.
"""

from __future__ import annotations

from sqlalchemy import case

from ..config import get_settings
from ..db.models import DailyChallengePlay


def bonus_allowance(score: int | None) -> int:
    """Extra questions one finished play grants; 0 when the reward is off."""
    s = get_settings()
    if s.daily_bonus_questions <= 0:
        return 0
    top = (score or 0) >= s.daily_bonus_top_score
    return s.daily_bonus_questions + (s.daily_bonus_top_score_extra if top else 0)


def bonus_allowance_sql():
    """``bonus_allowance`` as a column expression, for the guarded spend."""
    s = get_settings()
    return s.daily_bonus_questions + case(
        (
            DailyChallengePlay.score >= s.daily_bonus_top_score,
            s.daily_bonus_top_score_extra,
        ),
        else_=0,
    )
