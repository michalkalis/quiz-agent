"""Game part of the room state (#212.2), shared by every room reply."""

from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field

from quiz_shared.models.session import QuizSession

from ...rooms import rounds
from ...rooms.awards import awards


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
    # #224.4: set (true) only while the host holds the reveal; absent otherwise.
    # #249.4: also while the host pauses the open question (reading or
    # answering): remaining_ms then stands still and answers still count.
    paused: Optional[bool] = Field(
        None,
        description="True while the host pauses (the reveal, or the open "
        "question with its clock stopped); absent otherwise",
    )
    # #239: set (true) only when the judge could not grade the question and the
    # host moved on; every result is then "skipped" with 0 points. Absent otherwise.
    cancelled: Optional[bool] = None


class RankOut(BaseModel):
    participant_id: str
    rank: int
    score: float
    correct_count: int


class AwayOut(BaseModel):
    participant_id: str
    questions: int = Field(description="Questions during which they left the app")


class AwardOut(BaseModel):
    """#240.9: a small award on the final screen."""

    kind: str = Field(
        description="fastest (fastest right answer) | only_one (the only one "
        "right on a question) | streak (most right answers in a row, 3 or more); "
        "apps skip a kind they do not know"
    )
    participant_id: str
    question_number: Optional[int] = Field(
        None, description="fastest: that question; only_one: the first such question"
    )
    ms: Optional[int] = Field(
        None, description="fastest: time from the question appearing to the answer"
    )
    count: Optional[int] = Field(
        None, description="only_one: how many questions; streak: its length"
    )


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
    awards: Optional[List[AwardOut]] = Field(
        None, description="Once finished, with 2+ players (#240.9)"
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
        paused=True if rnd.paused_at is not None else None,
    )
    if rnd.closed:
        out.correct_answer = rnd.correct_answer
        out.explanation = rnd.explanation
        out.paused = True if rnd.paused else None
        out.cancelled = True if rnd.cancelled else None
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
        view.awards = [AwardOut(**a.__dict__) for a in awards(session)] or None
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
    answers in full. #249.4: also during a pause of the open question, so a
    build that does not know it keeps re-reading the stopped time left."""
    game = session.room_game
    rnd = game.current if game else None
    if rnd is not None and rnd.paused_at is not None:
        return False
    return rnd is None or rounds.phase(session, rnd, rounds.now()) in (
        "answering",
        "revealed",
    )
