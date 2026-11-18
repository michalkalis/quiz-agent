"""When the crowd is mentioned, and how (#205 rules table, founder 2026-10-15).

Pure functions over real counts — never seeded or estimated numbers. "Others"
never includes the player's own answer.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, Optional

# A question at most this share of others knew is "rare" (correct answer) or
# "hard" (wrong answer).
RARE_SHARE = 0.30
# From this many other players the strip shows a percentage, below it counts
# (founder decision 5).
PERCENT_FROM = 20
# Crowd lines the host may speak in one challenge.
MAX_SPOKEN_LINES = 3

CrowdKind = Literal["first", "rare", "plain", "hard", "hidden"]


@dataclass(frozen=True)
class Crowd:
    """How the other players of the day did on one question."""

    others: int
    knew: int

    @property
    def share(self) -> Optional[float]:
        return self.knew / self.others if self.others else None

    @property
    def uses_percent(self) -> bool:
        return self.others >= PERCENT_FROM

    @property
    def percent(self) -> int:
        return round(100 * self.knew / self.others) if self.others else 0


def classify(crowd: Crowd, player_knew: bool) -> CrowdKind:
    """The rules table: rare and hard are worth saying; a common correct answer
    gets a plain strip; a wrong answer most others knew gets nothing at all
    (negative comparison is the one line with measured harm)."""
    if crowd.others == 0:
        return "first"
    rare = crowd.knew / crowd.others <= RARE_SHARE
    if player_knew:
        return "rare" if rare else "plain"
    return "hard" if rare else "hidden"


def is_spoken(kind: CrowdKind, spoken_so_far: int) -> bool:
    return kind in ("rare", "hard") and spoken_so_far < MAX_SPOKEN_LINES


def knew(result: str) -> bool:
    """A verdict that counts as knowing the answer."""
    return result in ("correct", "partially_correct")


@dataclass(frozen=True)
class Standing:
    """The player's finished score among the day's other finished players."""

    others: int
    beaten: int
    score: int
    total: int

    @property
    def top_half(self) -> bool:
        """Strictly better than at least half of the others. Rank is only ever
        shown here — never "worse than…"."""
        return self.others > 0 and self.beaten * 2 >= self.others

    @property
    def beat_everyone(self) -> bool:
        return self.others > 0 and self.beaten == self.others


# #239 rarity points (founder 2026-11-18): a correct answer everyone knew is
# worth COMMON_POINTS, one nobody else knew up to RARE_POINTS.
COMMON_POINTS = 10
RARE_POINTS = 100


def rarity_points(answered: int, knew_count: int) -> int:
    """Points for one correct answer, from everyone who answered that question
    that day (the player included, so a lone player gets the common points and
    a tiny crowd never swings to the extremes). Recomputed live as others play."""
    if answered <= 0:
        return COMMON_POINTS
    share = min(1.0, knew_count / answered)
    return round(COMMON_POINTS + (RARE_POINTS - COMMON_POINTS) * (1 - share))
