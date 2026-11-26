"""#249.4: the host pauses an open question of a game together.

Why it matters: the answer clock is the server's and shared by every phone,
so a pause that only stopped the host's screen would let the time run out
for everyone else (founder test 2026-11-26: "there is no pause"). A paused
question must keep its time left, keep taking answers, never be closed by
the lazy close a poll triggers, and only the host may pause it. Answer speed
(tie-break, "fastest" award) must not count the pause.
"""

from __future__ import annotations

import pytest

from app.rooms import rounds

from .test_room_play import game  # noqa: F401  (fixture)

pytestmark = pytest.mark.asyncio

GRACE = rounds.ANSWER_GRACE.total_seconds()


async def _current(game):  # noqa: F811
    session = await game.sessions.get_session(game.session_id)
    return session.room_game.current


async def test_a_pause_while_answering_stops_the_clock_for_everyone(game):  # noqa: F811
    # 10 s thinking + 5 s for A–D = 15 s; 4 s gone when the host pauses.
    await game.setup(thinking_seconds=10)
    await game.post("open", question_id="q_mcq")
    game.clock.tick(4)
    assert (await game.post("pause", paused=True)).status_code == 200

    game.clock.tick(60)  # a long break at the table
    for who in ("host", "jana"):
        rnd = (await game.state(who))["round"]
        assert rnd["phase"] == "answering" and rnd["paused"] is True
        assert rnd["remaining_ms"] == 11_000, "the time left must stand still"

    assert (await game.post("pause", paused=False)).status_code == 200
    rnd = (await game.state("jana"))["round"]
    assert "paused" not in rnd and rnd["remaining_ms"] == 11_000
    # The deadline moved on by the pause: just before it the question is open,
    # past it (and the grace) it closes as before.
    game.clock.tick(11 + GRACE - 0.1)
    assert (await game.answer("peto", "q_mcq", "b")).status_code == 200
    game.clock.tick(0.2)
    assert (await game.answer("jana", "q_mcq", "b")).status_code == 409


async def test_the_lazy_close_never_closes_a_paused_question(game):  # noqa: F811
    # Polls close a question past its time in the background; during a pause
    # that would end the question under the players' hands.
    await game.setup(thinking_seconds=10)
    await game.post("open", question_id="q_mcq")
    await game.post("pause", paused=True)
    game.clock.tick(10_000)
    assert (await game.state("jana"))["round"]["phase"] == "answering"
    await game.settle()
    await game.service.play._close(game.session_id)
    assert game.judge.calls == []
    assert (await _current(game)).closed is False
    # Nor does the host's Next: the players still have their time.
    assert (await game.post("next")).status_code == 409


async def test_answers_count_while_paused_and_the_pause_is_not_their_speed(game):  # noqa: F811
    await game.setup(thinking_seconds=10)
    await game.post("open", question_id="q_mcq")
    game.clock.tick(4)
    await game.post("pause", paused=True)
    game.clock.tick(30)
    assert (await game.answer("jana", "q_mcq", "b")).status_code == 200
    assert (await game.answer("host", "q_mcq", "a")).status_code == 200
    # Everyone but Peťo is in; even the last answer during a pause would not
    # reveal (the host paused to talk, not to see the answer).
    assert (await game.answer("peto", "q_mcq", "b")).status_code == 200
    assert (await game.state())["round"]["phase"] == "answering"
    assert game.judge.calls == []

    game.clock.tick(20)
    await game.post("pause", paused=False)
    await game.settle()
    rnd = (await game.state("jana"))["round"]
    assert rnd["phase"] == "revealed"
    current = await _current(game)
    jana = await game.pid("jana")
    # Answered "during" the pause = at the pause on the round's clock: 4 s.
    assert rounds.answer_ms(current, current.answers[jana]) == 4_000


async def test_a_pause_while_the_host_reads_holds_the_reading_fallback(game):  # noqa: F811
    # The server starts the time by itself 45 s after serving (a host phone
    # that died mid-read); a pause during reading must push that too.
    await game.setup(thinking_seconds=10)
    game.clock.tick(3)
    await game.post("pause", paused=True)
    game.clock.tick(100)
    rnd = (await game.state("jana"))["round"]
    assert rnd["phase"] == "reading" and rnd["paused"] is True
    assert "remaining_ms" not in rnd
    await game.post("pause", paused=False)
    game.clock.tick(41)
    assert (await game.state("jana"))["round"]["phase"] == "reading"
    game.clock.tick(2)
    rnd = (await game.state("jana"))["round"]
    assert rnd["phase"] == "answering" and rnd["remaining_ms"] == 14_000


async def test_a_read_that_ends_during_the_pause_starts_the_clock_at_the_resume(
    game,  # noqa: F811
):
    await game.setup(thinking_seconds=10)
    await game.post("pause", paused=True)
    game.clock.tick(7)
    # The host's phone finished its clip as the pause landed.
    assert (await game.post("open", question_id="q_mcq")).status_code == 200
    game.clock.tick(20)
    assert (await game.state("jana"))["round"]["remaining_ms"] == 15_000
    await game.post("pause", paused=False)
    game.clock.tick(5)
    assert (await game.state("jana"))["round"]["remaining_ms"] == 10_000


async def test_only_the_host_pauses_and_a_question_out_of_time_cannot(game):  # noqa: F811
    await game.setup(thinking_seconds=10)
    await game.post("open", question_id="q_mcq")
    assert (await game.post("pause", "jana", paused=True)).status_code == 403
    await game.post("pause", paused=True)
    assert (await game.post("pause", "jana", paused=False)).status_code == 403
    assert (await game.state("jana"))["round"]["paused"] is True
    # Repeats change nothing (a retried tap).
    v = (await game.state())["version"]
    assert (await game.post("pause", paused=True)).status_code == 200
    assert (await game.state())["version"] == v
    await game.post("pause", paused=False)
    # Past the deadline the answers are being checked: nothing to pause.
    game.clock.tick(15 + GRACE)
    assert (await game.post("pause", paused=True)).status_code == 409


async def test_a_paused_poll_is_answered_in_full_for_builds_without_the_pause(
    game,  # noqa: F811
):
    # Builds before #249.4 count down locally between full replies; a tiny
    # "unchanged" reply during a pause would let their timer run to zero.
    await game.setup()
    await game.post("open", question_id="q_mcq")
    await game.post("pause", paused=True)
    v = (await game.state("jana"))["version"]
    again = await game.state("jana", since=v)
    assert again["changed"] is True and again["round"]["remaining_ms"] > 0
