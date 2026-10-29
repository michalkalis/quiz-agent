"""Game part of the room state (#212.2), shared by every room reply."""

from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field

from quiz_shared.models.session import QuizSession

from ...rooms import rounds


class RoundResult(BaseModel):
    participant_id: str
    answer: str
    result: str = Field(description="correct | partially_correct | … | incorrect")
    points: float


class RoundOut(BaseModel):
    question_id: str
    number: int
    question_text: str
    phase: str = Field(description="reading | answering | grading | revealed")
    remaining_ms: Optional[int] = Field(
        None, description="Answer time left; null while the host reads aloud"
    )
    answered: List[str] = Field(description="participant_ids that answered")
    your_answer: Optional[str] = None
    # Filled once the question closed (phase revealed).
    correct_answer: Optional[str] = None
    explanation: Optional[str] = None
    results: Optional[List[RoundResult]] = None


class RankOut(BaseModel):
    participant_id: str
    rank: int
    score: float
    correct_count: int


class AwayOut(BaseModel):
    participant_id: str
    questions: int = Field(description="Questions during which they left the app")


class GameView(BaseModel):
    """The game part of the room state (all optional: lobby has none)."""

    reveal_mode: Optional[str] = Field(None, description="question | round")
    thinking_seconds: Optional[int] = Field(
        None, description="Answer time the host chose (from the next question)"
    )
    reads_aloud: Optional[bool] = Field(
        None, description="The host's phone reads the questions aloud"
    )
    question: Optional[Dict[str, Any]] = Field(
        None, description="Current question, same shape as solo current_question"
    )
    round: Optional[RoundOut] = None
    finished_reason: Optional[str] = Field(
        None, description="max_questions | usage_limit | no_more_questions"
    )
    ranking: Optional[List[RankOut]] = None
    rounds: Optional[List[RoundOut]] = Field(
        None, description="Every question with its results, once finished"
    )
    away: Optional[List[AwayOut]] = Field(
        None, description="Host only, once finished: who left the app (#212.4)"
    )


def round_out(session: QuizSession, rnd, you, at: datetime) -> RoundOut:
    game = session.room_game
    phase = rounds.phase(session, rnd, at)
    mine = rnd.answers.get(you.participant_id)
    out = RoundOut(
        question_id=rnd.question_id,
        number=rnd.number,
        question_text=rnd.question.get("question", ""),
        phase=phase,
        remaining_ms=rounds.remaining_ms(game, rnd, at) if not rnd.closed else 0,
        answered=list(rnd.answers),
        your_answer=mine.answer if mine else None,
    )
    if rnd.closed:
        out.correct_answer = rnd.correct_answer
        out.explanation = rnd.explanation
        out.results = [
            RoundResult(
                participant_id=pid, answer=a.answer, result=a.result, points=a.points
            )
            for pid, a in rnd.answers.items()
        ]
    return out


def game_view(session: QuizSession, you) -> GameView:
    game = session.room_game
    if game is None:
        return GameView()
    at = rounds.now()
    rnd = game.current
    view = GameView(
        reveal_mode=game.reveal_mode,
        thinking_seconds=game.thinking_seconds,
        reads_aloud=game.reads_aloud,
        question=rnd.question if rnd else None,
        round=round_out(session, rnd, you, at) if rnd else None,
        finished_reason=game.finished_reason,
    )
    if game.finished_reason:
        view.ranking = [
            RankOut(
                participant_id=p.participant_id,
                rank=i + 1,
                score=p.score,
                correct_count=p.correct_count,
            )
            for i, p in enumerate(rounds.ranking(session))
        ]
        view.rounds = [round_out(session, r, you, at) for r in game.rounds]
        if you.is_host:
            counts: Dict[str, int] = {}
            for r in game.rounds:
                for pid in r.away:
                    counts[pid] = counts.get(pid, 0) + 1
            view.away = [
                AwayOut(participant_id=k, questions=v) for k, v in counts.items()
            ]
    return view


def stable(session: QuizSession) -> bool:
    """True when an unchanged version means an unchanged screen. While the host
    reads or a close is pending, the phase moves with time alone, so the poll
    answers in full."""
    game = session.room_game
    rnd = game.current if game else None
    return rnd is None or rounds.phase(session, rnd, rounds.now()) in (
        "answering",
        "revealed",
    )
