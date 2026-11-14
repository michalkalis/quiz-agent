"""#232.2b shared quiz comparison — who sees whom, and a ✓/✗ per question.

Why (founder 2026-11-14): a link travels further than the sender meant it to
(forwarded in a group chat), so the comparison is filtered on the server. A
friend sees only themselves and the sender — never another friend's name or
score, not even how many others played (the "Player N" numbers). The sender
sees everyone. Anyone else holding the token sees nothing. The marks must
follow the share's question order, or the screen puts a ✓ on the wrong
question; a question a player was never served is "not played", not "wrong".
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from quiz_shared.models.participant import Participant
from quiz_shared.models.room import RoomAnswer, RoomGame, RoomRound

from tests.test_idempotent_submit import (
    _Q1,
    _FakeSessionManager,
    _flow,
    _submit,
)
from tests.test_idempotent_submit import _session as _flow_session
from tests.test_shared_quiz import (  # noqa: F401 — fixtures
    PENDING,
    _finish,
    _finished,
    _h,
    _session,
    _share,
    _start,
    app,
    client,
)

pytestmark = pytest.mark.asyncio


async def _results(client, token, viewer):  # noqa: F811
    return await client.get(
        f"/api/v1/shared-quizzes/{token}/results", headers=_h(viewer)
    )


async def _round_share(client, app):  # noqa: F811
    sender = await _finished(app, "sender", ["q1", "q2", "q3"], score=2.0)
    return (
        await _share(client, "sender", session_id=sender.session_id, display_name="Mia")
    )["token"]


async def _play(client, app, token, subject, score, name=None):  # noqa: F811
    resp = await _start(
        client, token, subject, **({"display_name": name} if name else {})
    )
    await _finish(app, await _session(app, resp), score)


async def test_a_friend_never_sees_other_friends(client, app):  # noqa: F811
    token = await _round_share(client, app)
    await _play(client, app, token, "ana", 3.0, "Ana")
    await _play(client, app, token, "boris", 1.0, "Boris")
    await _play(client, app, token, "anon", 0.0)

    for viewer, me in [("ana", "Ana"), ("boris", "Boris")]:
        players = (await _results(client, token, viewer)).json()["players"]
        assert {p["name"] for p in players} == {me, "Mia"}, viewer
        assert [p["is_you"] for p in players if p["name"] == me] == [True]
    # Unnamed: numbered among what this viewer sees, so "Player 1" — a
    # "Player 3" would tell them two others played.
    players = (await _results(client, token, "anon")).json()["players"]
    assert [(p["name"], p["score"]) for p in players] == [
        ("Mia", 2.0),
        ("Player 1", 0.0),
    ]


async def test_the_sender_sees_everyone(client, app):  # noqa: F811
    token = await _round_share(client, app)
    await _play(client, app, token, "ana", 3.0, "Ana")
    players = (await _results(client, token, "sender")).json()["players"]
    # One friend: just the two of them.
    assert [p["name"] for p in players] == ["Ana", "Mia"]
    await _play(client, app, token, "boris", 1.0, "Boris")
    players = (await _results(client, token, "sender")).json()["players"]
    assert [p["name"] for p in players] == ["Ana", "Mia", "Boris"]
    assert [p["is_you"] for p in players] == [False, True, False]


async def test_someone_who_only_holds_the_token_sees_nothing(client, app):  # noqa: F811
    token = await _round_share(client, app)
    await _play(client, app, token, "ana", 3.0, "Ana")
    assert (await _results(client, token, "stranger")).status_code == 404
    # Started but not finished yet: a friend already, sees only the sender.
    await _start(client, token, "late")
    players = (await _results(client, token, "late")).json()["players"]
    assert [p["name"] for p in players] == ["Mia"]


async def test_marks_follow_the_shares_question_order(client, app):  # noqa: F811
    sender = await _finished(
        app,
        "sender",
        ["q1", "q2", PENDING, "q3"],
        question_results={
            "q3": "skipped",
            PENDING: "correct",
            "q1": "correct",
            "q2": "incorrect",
        },
    )
    token = (await _share(client, "sender", session_id=sender.session_id))["token"]
    # q2 is pulled before the friend plays: never served to them → null.
    app.state.shared_quiz.retriever.status["q2"] = "pending_review"
    friend = await _session(app, await _start(client, token, "ana"))
    friend.question_results = {"q3": "correct", "q1": "partially_correct"}
    await _finish(app, friend, 1.5)

    players = (await _results(client, token, "ana")).json()["players"]
    marks = {p["is_sender"]: p["marks"] for p in players}
    assert marks[True] == [True, False, False]  # TestFlight-only row left out
    assert marks[False] == [True, None, True]


async def _room_marks(client, app, token, guest_joined):  # noqa: F811
    """A game together with three closed rounds served a minute apart; the
    guest's marks as the guest sees them."""
    host = await _session(app, await _start(client, token, "host"))
    start = datetime.now(timezone.utc) - timedelta(minutes=10)
    host.participants = [
        Participant(
            participant_id="p-host",
            user_id="host",
            display_name="Host",
            joined_at=start,
        ),
        Participant(
            participant_id="p-guest",
            user_id="guest",
            display_name="Guest",
            joined_at=start + guest_joined,
        ),
    ]
    rounds = [
        ("q1", {"p-host": "correct", "p-guest": "incorrect"}),
        ("q2", {"p-host": "incorrect"}),  # guest did not answer
        ("q3", {"p-host": "correct", "p-guest": "correct"}),
    ]
    host.room_game = RoomGame(
        rounds=[
            RoomRound(
                question_id=qid,
                number=i + 1,
                question={},
                is_open=True,
                served_at=start + timedelta(minutes=i + 1),
                closed=True,
                answers={
                    pid: RoomAnswer(answer="x", at=start, result=result)
                    for pid, result in answers.items()
                },
            )
            for i, (qid, answers) in enumerate(rounds)
        ]
    )
    await _finish(app, host, 2.0)
    players = (await _results(client, token, "guest")).json()["players"]
    return next(p["marks"] for p in players if p["is_you"])


async def test_a_game_together_marks_every_player(client, app):  # noqa: F811
    token = await _round_share(client, app)
    assert await _room_marks(client, app, token, timedelta(0)) == [
        False,
        False,
        True,
    ]


async def test_a_late_joiner_has_no_mark_for_what_came_before(client, app):  # noqa: F811
    """A ✗ on a question served before they joined would read as a wrong
    answer they never gave."""
    token = await _round_share(client, app)
    late = timedelta(minutes=2, seconds=30)  # after q1 and q2 were served
    assert await _room_marks(client, app, token, late) == [None, None, True]


async def test_daily_marks_cover_the_whole_play(client, app):  # noqa: F811
    """A challenge resumed in a second session: the marks come from the play,
    which saw every answer, not only from the session that finished it."""
    daily = app.state.shared_quiz.daily
    today = datetime.now(timezone.utc).date()
    set_ids = await daily.question_ids("en", today)
    sender = await _finished(
        app, "sender", set_ids, daily_challenge_date=today.isoformat()
    )
    token = (await _share(client, "sender", session_id=sender.session_id))["token"]
    play, remaining = await daily.begin("friend", "en", today)
    first = await _finished(app, "friend", [], daily_challenge_date=today.isoformat())
    await daily.attach_session(play.id, first.session_id)
    await daily.record_answer(first, remaining[0], "incorrect")

    resumed = await _session(app, await _start(client, token, "friend"))
    for qid in resumed.fixed_question_ids:
        await daily.record_answer(resumed, qid, "correct")
        resumed.question_results[qid] = "correct"
    await daily.finish(resumed)
    await _finish(app, resumed, 4.0)

    players = (await _results(client, token, "friend")).json()["players"]
    friend = next(p for p in players if p["is_you"])
    assert friend["marks"] == [False, True, True, True, True]


async def test_every_verdict_lands_in_the_session_and_a_regrade_replaces_it():
    """The marks are read from the session at finish, so the answer flow must
    write each verdict there — and an edited transcript must replace it."""
    manager = _FakeSessionManager(_flow_session())
    flow = _flow(manager)
    await _submit(flow, manager, "Paris", question_id=_Q1)
    assert manager.stored.question_results == {_Q1: "correct"}
    await _submit(flow, manager, "Lyon", question_id=_Q1)
    assert manager.stored.question_results == {_Q1: "incorrect"}
