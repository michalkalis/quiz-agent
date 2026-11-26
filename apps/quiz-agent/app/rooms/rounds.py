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
            thinking_seconds=game.thinking_seconds,
        )
    )


def game_time(rnd: RoomRound, at: datetime) -> datetime:
    """The round's own clock (#249.4): it stands still while the host pauses
    the open question, so every check made during a pause sees its start."""
    return min(at, rnd.paused_at) if rnd.paused_at else at


def resume(rnd: RoomRound, at: datetime) -> None:
    """End the host's pause: every time of the round moves on by the pause,
    so the time left, the reading fallback and every answer's speed are as
    if the pause never happened. Answers sent during it were stored at its
    start and land on the resume instant."""
    if rnd.paused_at is None:
        return
    gap = max(timedelta(0), at - rnd.paused_at)
    rnd.served_at += gap
    if rnd.opened_at is not None:
        rnd.opened_at += gap
    for a in rnd.answers.values():
        a.at += gap
    rnd.paused_at = None


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
    thinking = (
        rnd.thinking_seconds
        if rnd.thinking_seconds is not None
        else game.thinking_seconds
    )
    return clock_start(rnd) + timedelta(seconds=thinking + extra)


def all_answered(session: QuizSession, rnd: RoomRound) -> bool:
    return all(p.participant_id in rnd.answers for p in session.participants)


def accepts_answers(game: RoomGame, rnd: RoomRound, at: datetime) -> bool:
    return not rnd.closed and game_time(rnd, at) < deadline(game, rnd) + ANSWER_GRACE


def close_due(session: QuizSession, at: datetime) -> bool:
    game = session.room_game
    rnd = game.current if game else None
    # #249.4: a paused question never closes, not even with every answer in.
    if rnd is None or rnd.closed or rnd.paused_at is not None:
        return False
    return all_answered(session, rnd) or not accepts_answers(game, rnd, at)


def phase(session: QuizSession, rnd: RoomRound, at: datetime) -> str:
    """reading → answering → grading → revealed."""
    if rnd.closed:
        return "revealed"
    if close_due(session, at):
        return "grading"
    if rnd.opened_at is None and game_time(rnd, at) < clock_start(rnd):
        return "reading"
    return "answering"


def remaining_ms(game: RoomGame, rnd: RoomRound, at: datetime) -> Optional[int]:
    """Milliseconds left to answer (phones count down from this, never from
    their own clock). None while the host is still reading; it stands still
    while the host pauses."""
    at = game_time(rnd, at)
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
