"""Clock and ranking of a room's questions (#212.2). Pure: no I/O, so the
solo serve paths can open a round without importing the room flow."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

from quiz_shared.models.participant import Participant
from quiz_shared.models.room import RoomAnswer, RoomGame, RoomRound
from quiz_shared.models.session import QuizSession

from ..config import get_settings

# An answer sent as the phone's countdown hits zero still counts: it needs a
# moment to arrive. The question closes only after this grace.
ANSWER_GRACE = timedelta(seconds=2)


def now() -> datetime:
    return datetime.now(timezone.utc)


def open_round(session: QuizSession, payload: Dict[str, Any]) -> None:
    """Called wherever a question is served (/start, the room's next question):
    in a room it becomes the question everyone answers. No-op for solo."""
    game = session.room_game
    if game is None:
        return
    game.rounds.append(
        RoomRound(
            question_id=session.current_question_id,
            number=len(session.asked_question_ids),
            question=payload,
            is_open=not payload.get("possible_answers"),
            served_at=now(),
        )
    )


def clock_start(rnd: RoomRound) -> datetime:
    """When the answer time starts: the host's "read aloud done", or a fallback
    so a host phone that died mid-read cannot stall the room."""
    fallback = timedelta(seconds=get_settings().room_read_fallback_seconds)
    return rnd.opened_at or rnd.served_at + fallback


def deadline(game: RoomGame, rnd: RoomRound) -> datetime:
    settings = get_settings()
    extra = (
        settings.room_open_extra_seconds
        if rnd.is_open
        else settings.room_mcq_extra_seconds
    )
    return clock_start(rnd) + timedelta(seconds=game.thinking_seconds + extra)


def all_answered(session: QuizSession, rnd: RoomRound) -> bool:
    return all(p.participant_id in rnd.answers for p in session.participants)


def accepts_answers(game: RoomGame, rnd: RoomRound, at: datetime) -> bool:
    return not rnd.closed and at < deadline(game, rnd) + ANSWER_GRACE


def close_due(session: QuizSession, at: datetime) -> bool:
    game = session.room_game
    rnd = game.current if game else None
    if rnd is None or rnd.closed:
        return False
    return all_answered(session, rnd) or not accepts_answers(game, rnd, at)


def phase(session: QuizSession, rnd: RoomRound, at: datetime) -> str:
    """reading → answering → grading → revealed."""
    if rnd.closed:
        return "revealed"
    if close_due(session, at):
        return "grading"
    if rnd.opened_at is None and at < clock_start(rnd):
        return "reading"
    return "answering"


def remaining_ms(game: RoomGame, rnd: RoomRound, at: datetime) -> Optional[int]:
    """Milliseconds left to answer (phones count down from this, never from
    their own clock). None while the host is still reading."""
    if rnd.opened_at is None and at < clock_start(rnd):
        return None
    return max(0, int((deadline(game, rnd) - at).total_seconds() * 1000))


def answer_ms(rnd: RoomRound, answer: RoomAnswer) -> int:
    """How fast the answer came after the clock started (0 = while reading)."""
    return max(0, int((answer.at - clock_start(rnd)).total_seconds() * 1000))


def ranking(session: QuizSession) -> List[Participant]:
    """Points first; a tie goes to whoever was faster on their correct answers."""
    game = session.room_game
    rounds = game.rounds if game else []

    def correct_ms(p: Participant) -> int:
        return sum(
            answer_ms(r, a)
            for r in rounds
            for pid, a in r.answers.items()
            if pid == p.participant_id and a.result == "correct"
        )

    return sorted(session.participants, key=lambda p: (-p.score, correct_ms(p)))
