"""#240.9: the parts of a game together the founder asked for on 2026-11-18.

What matters:
- "Play again" keeps the people: the host's room moves to a new session with
  everyone in it, under the same id, link and QR, so nobody is invited again
  and every phone (polling the same room) simply lands in the new lobby.
- Other content in the lobby does the same, so a link already sent still works.
- No silent waiting: while the last answer is judged every phone sees
  "grading", and a player who leaves mid-question does not hold the others
  until the time is up.
- The end has more than one moment: small awards from the game's own data.
- Every new step is measured (game started, play again).
"""

from __future__ import annotations

import asyncio

import pytest

from app.rooms import rounds

from .test_room_play import _h, game  # noqa: F401  (fixture)

pytestmark = pytest.mark.asyncio


async def _finish_one_question_game(game, answers):  # noqa: F811
    await game.setup(max_questions=1)
    await game.post("open", question_id="q_mcq")
    for who, text in answers:
        assert (await game.answer(who, "q_mcq", text)).status_code == 200
    end = (await game.post("next")).json()
    assert end["status"] == "finished"
    return end


async def _again(game, who="host", room_id=None, **body):  # noqa: F811
    """The host's app: a fresh session, then the room moved onto it."""
    session = await game.sessions.create_session(user_id="host", max_questions=1)
    r = await game.c.post(
        "/api/v1/rooms",
        json={
            "session_id": session.session_id,
            "host_name": "Michal",
            "room_id": room_id or game.room_id,
            **body,
        },
        headers=_h(who),
    )
    return r, session.session_id


async def test_play_again_keeps_everyone_the_link_and_the_room(game):  # noqa: F811
    end = await _finish_one_question_game(
        game, [("host", "b"), ("jana", "b"), ("peto", "a")]
    )
    ids = {who: await game.pid(who) for who in ("host", "jana", "peto")}
    seen = (await game.state("jana"))["version"]
    link = (await game.service.store.get(game.room_id, rounds.now())).join_token

    r, new_session = await _again(game)
    assert r.status_code == 200, r.text
    assert r.json() == {
        "room_id": game.room_id,
        "join_token": link,
        "session_id": new_session,
    }

    # A guest's phone polls the same room with the last version it saw and
    # gets the new lobby: same people, same ids, scores back at zero.
    lobby = await game.state("jana", since=seen)
    assert lobby["changed"] is True and lobby["version"] > seen
    assert lobby["status"] == "lobby" and lobby["you"] == ids["jana"]
    assert {p["participant_id"]: p["score"] for p in lobby["players"]} == {
        ids["host"]: 0.0,
        ids["jana"]: 0.0,
        ids["peto"]: 0.0,
    }
    assert "ranking" not in lobby and "round" not in lobby
    assert end["ranking"]  # the finished game had one

    # The invitation link sent before the first game still leads in.
    joined = await game.c.post(
        "/api/v1/rooms/join",
        json={"display_name": "Zuza", "join_token": link},
        headers=_h("zuza"),
    )
    assert joined.status_code == 200, joined.text
    assert len(joined.json()["players"]) == 4

    started = await game.c.post(
        f"/api/v1/sessions/{new_session}/start", json={}, headers=_h("host")
    )
    assert started.status_code == 200, started.text
    rows = [(n, p) for n, _, p in game.events.rows if n.startswith("room_")]
    assert ("room_rematch", {"room_id": game.room_id, "players": 3}) in rows
    assert [p["rematch"] for n, p in rows if n == "room_started"] == [False, True]
    assert [n for n, _ in rows].count("room_created") == 1


async def test_play_again_is_only_for_the_host_and_never_mid_game(game):  # noqa: F811
    await game.setup()
    r, _ = await _again(game)
    assert r.status_code == 409  # a question is being played
    r, _ = await _again(game, who="jana")
    assert r.status_code == 404  # not the host's session
    session = await game.sessions.create_session(user_id="jana")
    stolen = await game.c.post(
        "/api/v1/rooms",
        json={
            "session_id": session.session_id,
            "host_name": "Jana",
            "room_id": game.room_id,
        },
        headers=_h("jana"),
    )
    assert stolen.status_code == 404  # a guest cannot take the room over
    assert (await game.state("peto"))["status"] == "playing"


async def test_other_content_in_the_lobby_keeps_the_link_and_the_guests(game):  # noqa: F811
    await game.setup(guests=("jana",), start=False)
    old = await game.sessions.get_session(game.session_id)
    r, new_session = await _again(game)
    assert r.status_code == 200 and r.json()["room_id"] == game.room_id
    assert r.json()["join_token"]
    lobby = await game.state("jana")
    assert lobby["status"] == "lobby" and len(lobby["players"]) == 2
    # The room left the old session: a join that raced the move fails loudly
    # instead of landing in a session nobody plays.
    assert (await game.sessions.get_session(old.session_id)).room_code is None
    assert (await game.sessions.get_session(new_session)).room_code == game.room_id
    # Content picked in the lobby is not "play again".
    assert not any(n == "room_rematch" for n, _, _ in game.events.rows)


async def test_a_retried_move_returns_the_same_room(game):  # noqa: F811
    await game.setup(guests=("jana",), start=False)
    r, new_session = await _again(game)
    again = await game.c.post(
        "/api/v1/rooms",
        json={
            "session_id": new_session,
            "host_name": "Michal",
            "room_id": game.room_id,
        },
        headers=_h("host"),
    )
    assert again.status_code == 200 and again.json() == r.json()


async def test_every_phone_sees_grading_while_the_last_answer_is_judged(game):  # noqa: F811
    # Typed answers go to the judge model; that takes seconds. The others must
    # see the answers being checked, not a question that still looks open.
    gate = asyncio.Event()
    judge = game.judge
    plain = judge.evaluate

    async def slow(user_answer, question, question_text=""):
        await gate.wait()
        return await plain(user_answer, question, question_text)

    await game.setup()
    for who in ("host", "jana", "peto"):
        await game.answer(who, "q_mcq", "b")
    await game.post("next")
    await game.post("open", question_id="q_open")
    await game.answer("host", "q_open", "Paris")
    await game.answer("jana", "q_open", "Paris")
    judge.evaluate = slow
    last = asyncio.create_task(game.answer("peto", "q_open", "Lyon"))
    for _ in range(50):
        await asyncio.sleep(0)
        rnd = (await game.state("jana"))["round"]
        if rnd["phase"] == "grading":
            break
    assert rnd["phase"] == "grading" and len(rnd["answered"]) == 3
    gate.set()
    assert (await last).json()["round"]["phase"] == "revealed"


async def test_a_player_who_leaves_mid_question_does_not_hold_the_others(game):  # noqa: F811
    await game.setup()
    await game.post("open", question_id="q_mcq")
    await game.answer("host", "q_mcq", "b")
    await game.answer("jana", "q_mcq", "b")
    peto = await game.pid("peto")
    gone = await game.c.delete(
        f"/api/v1/rooms/{game.room_id}/players/{peto}", headers=_h("peto")
    )
    assert gone.status_code == 204
    await game.state()  # the next poll closes it, no waiting for the clock
    await game.settle()
    assert (await game.state("jana"))["round"]["phase"] == "revealed"


async def test_awards_give_a_moment_to_someone_besides_the_winner(game):  # noqa: F811
    # Q1: Peto is the fastest right answer (Jana is right too, later).
    # Q2: only Jana knows it. Jana wins on points, Peto still gets "fastest".
    await game.setup(max_questions=2, thinking_seconds=10)
    game.clock.tick(2)
    await game.answer("peto", "q_mcq", "b")
    game.clock.tick(3)
    await game.answer("jana", "q_mcq", "b")
    await game.answer("host", "q_mcq", "a")
    await game.post("next")
    await game.post("open", question_id="q_open")
    game.clock.tick(4)  # typing takes longer than Peto's tap on question 1
    for who, text in (("host", "Lyon"), ("jana", "Paris"), ("peto", "Nice")):
        await game.answer(who, "q_open", text)
    end = (await game.post("next")).json()
    pid = {p["display_name"]: p["participant_id"] for p in end["players"]}
    assert end["ranking"][0]["participant_id"] == pid["Jana"]
    awards = {a["kind"]: a for a in end["awards"]}
    assert awards["fastest"] == {
        "kind": "fastest",
        "participant_id": pid["Peto"],
        "question_number": 1,
        "ms": 2000,
    }
    assert awards["only_one"]["participant_id"] == pid["Jana"]
    assert awards["only_one"]["count"] == 1
    assert "streak" not in awards  # two questions cannot make a run of three
    assert (await game.state("peto"))["awards"] == end["awards"]  # guests too


async def test_a_game_alone_has_no_awards(game):  # noqa: F811
    await game.setup(guests=(), max_questions=1)
    await game.answer("host", "q_mcq", "b")
    end = (await game.post("next")).json()
    assert end["status"] == "finished" and "awards" not in end


async def test_a_new_game_is_measured_when_it_starts(game):  # noqa: F811
    await game.setup(guests=("jana",))
    started = [p for n, _, p in game.events.rows if n == "room_started"]
    assert started == [{"room_id": game.room_id, "players": 2, "rematch": False}]
