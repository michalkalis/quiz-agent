"""The shared-quiz comparison (#232): the sender and everyone who finished it,
best first. A player without a name from a game together is "Hráč N"
(numbered in the order they started, the sender first)."""

from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel

from ..db.models import SharedQuiz, SharedQuizResult

_PLAYER_WORD = {"sk": "Hráč", "cs": "Hráč", "en": "Player"}


class RankedPlayer(BaseModel):
    name: str
    score: float
    total: int
    is_sender: bool = False
    is_you: bool = False


def rank(
    share: SharedQuiz,
    results: List[SharedQuizResult],
    sender_ids: List[str],
    viewer_ids: List[str],
) -> List[RankedPlayer]:
    viewer = set(viewer_ids)
    sender = set(sender_ids)
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
                    is_you=share.sender_subject_id in viewer,
                ),
            )
        )
    for r in results:
        if r.subject_id in sender:
            continue
        entries.append(
            (
                r.display_name,
                RankedPlayer(
                    name="",
                    score=r.score or 0.0,
                    total=r.total or 0,
                    is_you=r.subject_id in viewer,
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
