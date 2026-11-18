"""The shared-quiz comparison (#232), best first, filtered by who looks
(founder 2026-11-14): the sender sees everyone who finished it; a friend sees
only themselves and the sender, so friends never see each other. A player
without a name from a game together is "Hráč N", numbered among the rows this
viewer sees (sender first), so the numbers never reveal how many others played.
"""

from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel, Field

from ..db.models import SharedQuiz, SharedQuizResult

_PLAYER_WORD = {"sk": "Hráč", "cs": "Hráč", "uk": "Гравець", "en": "Player"}


class RankedPlayer(BaseModel):
    name: str
    score: float
    total: int
    is_sender: bool = False
    is_you: bool = False
    marks: Optional[List[Optional[bool]]] = Field(
        default=None,
        description=(
            "#232.2b: one entry per question of the shared quiz, in its order: "
            "true = knew it, false = did not, null = not played. Null as a "
            "whole when not recorded (an older result)."
        ),
    )


def rank(
    share: SharedQuiz,
    results: List[SharedQuizResult],
    sender_ids: List[str],
    viewer_ids: List[str],
) -> List[RankedPlayer]:
    viewer = set(viewer_ids)
    sender = set(sender_ids)
    sees_everyone = bool(viewer & sender)
    entries: list[tuple[Optional[str], RankedPlayer]] = []
    if share.sender_score is not None:
        entries.append(
            (
                share.sender_name,
                RankedPlayer(
                    name="",
                    score=share.sender_score,
                    total=share.sender_total or 0,
                    is_sender=True,
                    is_you=sees_everyone,
                    marks=share.sender_marks,
                ),
            )
        )
    for r in results:
        if r.subject_id in sender:
            continue
        is_you = r.subject_id in viewer
        if not (sees_everyone or is_you):
            continue
        entries.append(
            (
                r.display_name,
                RankedPlayer(
                    name="",
                    score=r.score or 0.0,
                    total=r.total or 0,
                    is_you=is_you,
                    marks=r.marks,
                ),
            )
        )
    word = _PLAYER_WORD.get(share.language, _PLAYER_WORD["en"])
    number = 0
    for name, player in entries:
        if name:
            player.name = name
        else:
            number += 1
            player.name = f"{word} {number}"
    # Stable sort: equal scores keep the order they played in.
    return sorted((p for _, p in entries), key=lambda p: -p.score)
