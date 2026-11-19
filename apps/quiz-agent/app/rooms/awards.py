"""Small awards at the end of a game together (#240.9), so the table has more
than one moment: the fastest right answer, the only one who knew a question,
the longest run of right answers. Pure, computed from the rounds the server
already keeps; a cancelled question counts for nobody. When players tie, the
award goes to someone other than the winner first."""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional

from quiz_shared.models.room import RoomRound
from quiz_shared.models.session import QuizSession

from . import rounds as room_rounds

# A run shorter than this is not worth a line on the final screen.
MIN_STREAK = 3


@dataclass(frozen=True)
class Award:
    kind: str  # fastest | only_one | streak
    participant_id: str
    question_number: Optional[int] = None
    ms: Optional[int] = None
    count: Optional[int] = None


def _graded(session: QuizSession) -> List[RoomRound]:
    game = session.room_game
    return [r for r in (game.rounds if game else []) if r.closed and not r.cancelled]


def _pick(candidates: list, winner: Optional[str]):
    """Best first; among equals, someone who did not win the game."""
    if not candidates:
        return None
    best = candidates[0][0]
    tied = [c for c in candidates if c[0] == best]
    return next((c for c in tied if c[1] != winner), tied[0])


def awards(session: QuizSession) -> List[Award]:
    players = {p.participant_id for p in session.participants}
    if len(players) < 2:
        return []
    ranked = room_rounds.ranking(session)
    winner = ranked[0].participant_id if ranked else None
    graded = _graded(session)
    found: List[Award] = []

    fastest = [
        (
            max(0, int((a.at - r.served_at).total_seconds() * 1000)),
            pid,
            r.number,
        )
        for r in graded
        for pid, a in r.answers.items()
        if a.result == "correct" and pid in players
    ]
    fastest.sort(key=lambda c: (c[0], c[2]))
    if pick := _pick(fastest, winner):
        found.append(Award("fastest", pick[1], question_number=pick[2], ms=pick[0]))

    alone: dict[str, list[int]] = {}
    for r in graded:
        right = [pid for pid, a in r.answers.items() if a.result == "correct"]
        if len(right) == 1 and right[0] in players:
            alone.setdefault(right[0], []).append(r.number)
    only = sorted(
        ((-len(nums), pid, nums[0]) for pid, nums in alone.items()),
        key=lambda c: (c[0], c[2]),
    )
    if pick := _pick(only, winner):
        found.append(
            Award("only_one", pick[1], question_number=pick[2], count=-pick[0])
        )

    runs = []
    for pid in (p.participant_id for p in ranked):
        best = run = 0
        for r in graded:
            a = r.answers.get(pid)
            run = run + 1 if a and a.result == "correct" else 0
            best = max(best, run)
        if best >= MIN_STREAK:
            runs.append((-best, pid))
    runs.sort(key=lambda c: c[0])  # stable: ties stay in ranking order
    if pick := _pick(runs, winner):
        found.append(Award("streak", pick[1], count=-pick[0]))
    return found
