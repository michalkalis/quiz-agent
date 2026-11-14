"""Per-question marks of a shared quiz (#232.2b — ✓/✗ in the comparison).

A mark list follows the share's ``question_ids`` order: true (knew it, the
daily challenge's rule: correct or partially correct), false (did not, a skip
or no answer included) or null (this person was not served that question).
"""

from __future__ import annotations

from typing import Dict, List, Optional

from quiz_shared.models.session import QuizSession

from ..daily_challenge.rules import knew

Marks = List[Optional[bool]]


def known_in_session(session: QuizSession, subject_id: str) -> Dict[str, bool]:
    """question_id → knew it, for ``subject_id`` in this session. A game
    together grades on ``room_game``: a question served before the player
    joined was not played (left out → null), one they did not answer counts
    as not known. A solo session grades on ``question_results``."""
    if session.room_game is not None:
        player = next(
            (p for p in session.participants if p.user_id == subject_id), None
        )
        if player is None:
            return {}
        known = {}
        for rnd in session.room_game.rounds:
            if not rnd.closed or rnd.served_at < player.joined_at:
                continue
            answer = rnd.answers.get(player.participant_id)
            known[rnd.question_id] = bool(
                answer and answer.result and knew(answer.result)
            )
        return known
    return {qid: knew(result) for qid, result in session.question_results.items()}


def aligned(question_ids: List[str], known: Dict[str, bool]) -> Optional[Marks]:
    """``known`` in the share's order; None when nothing is known."""
    if not known:
        return None
    return [known.get(qid) for qid in question_ids]
