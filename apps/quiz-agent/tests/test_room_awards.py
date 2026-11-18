"""#240.9 awards at the end of a game together, as pure rules.

Why: the awards exist so that someone besides the winner has a moment at the
end. A tie must go to a non-winner, a question that was cancelled (the judge
was down) must not hand anyone an award, and a run of right answers counts
only from three in a row.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from quiz_shared.models.participant import Participant
from quiz_shared.models.room import RoomAnswer, RoomGame, RoomRound
from quiz_shared.models.session import QuizSession

from app.rooms.awards import awards

T0 = datetime(2026, 11, 18, 20, 0, tzinfo=timezone.utc)


def _session(scores: dict[str, float], rounds: list[dict[str, tuple]]) -> QuizSession:
    """``rounds``: per question, pid -> (result, seconds after it appeared);
    a key ``cancelled`` marks a cancelled question."""
    game = RoomGame()
    for n, spec in enumerate(rounds, start=1):
        served = T0 + timedelta(minutes=n)
        game.rounds.append(
            RoomRound(
                question_id=f"q{n}",
                number=n,
                question={},
                is_open=False,
                served_at=served,
                closed=True,
                cancelled=bool(spec.pop("cancelled", False)),
                answers={
                    pid: RoomAnswer(
                        answer="x", at=served + timedelta(seconds=s), result=result
                    )
                    for pid, (result, s) in spec.items()
                },
            )
        )
    return QuizSession(
        session_id="s",
        mode="multiplayer",
        room_game=game,
        participants=[
            Participant(participant_id=pid, display_name=pid, score=score)
            for pid, score in scores.items()
        ],
    )


def _by_kind(session):
    return {a.kind: a for a in awards(session)}


def test_a_tie_goes_to_someone_who_did_not_win():
    session = _session(
        {"win": 2, "other": 1},
        [
            {"win": ("correct", 3), "other": ("correct", 3)},
            {"win": ("correct", 5), "other": ("incorrect", 1)},
        ],
    )
    fastest = _by_kind(session)["fastest"]
    assert (fastest.participant_id, fastest.ms, fastest.question_number) == (
        "other",
        3000,
        1,
    )


def test_a_cancelled_question_gives_no_award():
    session = _session(
        {"a": 1, "b": 0},
        [
            {"a": ("correct", 9), "b": ("incorrect", 9)},
            {"cancelled": True, "b": ("correct", 1)},
        ],
    )
    found = _by_kind(session)
    assert found["fastest"].participant_id == "a"
    assert found["only_one"].participant_id == "a"


def test_only_one_counts_the_questions_nobody_else_knew():
    session = _session(
        {"a": 2, "b": 2},
        [
            {"a": ("correct", 4), "b": ("incorrect", 4)},
            {"a": ("incorrect", 4), "b": ("correct", 4)},
            {"a": ("correct", 4), "b": ("incorrect", 4)},
            {"a": ("incorrect", 4), "b": ("correct", 4)},
            {"a": ("correct", 4), "b": ("correct", 4)},
        ],
    )
    only = _by_kind(session)["only_one"]
    assert only.count == 2


def test_a_streak_needs_three_in_a_row():
    two = _session(
        {"a": 2, "b": 0},
        [{"a": ("correct", 1)}, {"a": ("correct", 1)}, {"b": ("incorrect", 1)}],
    )
    assert "streak" not in _by_kind(two)
    three = _session(
        {"a": 1, "b": 3},
        [
            {"a": ("correct", 1), "b": ("correct", 2)},
            {"b": ("correct", 2)},
            {"b": ("correct", 2)},
        ],
    )
    streak = _by_kind(three)["streak"]
    assert (streak.participant_id, streak.count) == ("b", 3)


def test_alone_there_is_nothing_to_award():
    assert awards(_session({"a": 1}, [{"a": ("correct", 1)}])) == []
