"""#235.6: a game together under real concurrency, on two machines.

Why: in a game together every phone talks to the server at once — guests
scan the QR in the same second, everyone answers as the countdown ends, the
host taps "next" while a late answer is still in the air. Prod runs two
machines on one Postgres, so two of those requests really do run in parallel.
The sequential room tests cannot show what a player would see then:

- two guests taking the last seat: one gets in, the other is told the game is
  full — never nine players, never a guest who "joined" but is not in the game;
- two answers at the same instant: both count, the question closes once;
- the host's next / removal racing a guest's answer: the answer either counts
  or is refused with a clear 4xx — never silently lost, never a 500;
- a deploy mid-game: the next machine continues the same game, scores intact.

Each "machine" is its own app + SessionManager (own in-process locks) sharing
only the database, like two prod machines. The overlap is forced, not hoped
for: the first request is parked inside its write (holding the session lease)
until the second one is observed waiting for that lease.
"""

from __future__ import annotations

import asyncio
import os

import pytest
import pytest_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

from app.api.routes import quiz as quiz_routes  # noqa: E402
from app.api.routes import room_play as play_routes  # noqa: E402
from app.api.routes import rooms as room_routes  # noqa: E402
from app.auth.tokens import TokenService  # noqa: E402
from app.coordination.leases import LeaseStore  # noqa: E402
from app.quiz.flow import QuizFlowService  # noqa: E402
from app.rate_limit import limiter  # noqa: E402
from app.rooms import rounds  # noqa: E402
from app.rooms.network import NetTickets  # noqa: E402
from app.rooms.play import RoomPlay  # noqa: E402
from app.rooms.service import MAX_PLAYERS, RoomService  # noqa: E402
from app.rooms.store import PostgresRoomStore  # noqa: E402
from app.session.manager import SessionManager  # noqa: E402
from app.session.store import PostgresSessionStore  # noqa: E402
from tests.test_room_play import (  # noqa: E402
    MCQ,
    OPEN,
    _SECRET,
    Clock,
    Events,
    Judge,
    Retriever,
    Usage,
    _h,
)

pytestmark = pytest.mark.asyncio


class _ParkableStore(PostgresSessionStore):
    """A machine's session store whose next write can be parked mid-request
    (the writer then holds the session lease)."""

    def __init__(self, sm) -> None:
        super().__init__(sm)
        self.armed = False
        self.parked = asyncio.Event()
        self.release = asyncio.Event()

    async def update(self, *args, **kwargs):
        if self.armed:
            self.armed = False
            self.parked.set()
            await self.release.wait()
        return await super().update(*args, **kwargs)


class _WatchedLeases(LeaseStore):
    def __init__(self, sm) -> None:
        super().__init__(sm)
        self.refused = asyncio.Event()

    async def try_acquire(self, name, holder, ttl_s):
        ok = await super().try_acquire(name, holder, ttl_s)
        if not ok:
            self.refused.set()
        return ok


class _Machine:
    def __init__(self, db, shared) -> None:
        retriever, judge, usage, events = shared
        self.store = _ParkableStore(db)
        self.leases = _WatchedLeases(db)
        self.sessions = SessionManager(store=self.store, leases=self.leases)
        rooms_store = PostgresRoomStore(db)
        flow = QuizFlowService(
            session_manager=self.sessions,
            input_parser=None,
            question_retriever=retriever,
            answer_evaluator=judge,
            tts_service=None,
            usage_tracker=usage,
            translation_service=None,
            analytics=events,
        )
        self.service = RoomService(
            self.sessions, rooms_store, NetTickets(_SECRET), events
        )
        self.service.play = RoomPlay(self.sessions, rooms_store, flow)
        app = FastAPI()
        app.state.limiter = limiter
        app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
        for r in (room_routes.router, play_routes.router, quiz_routes.router):
            app.include_router(r, prefix="/api/v1")
        app.state.token_service = TokenService(
            secret=_SECRET,
            issuer="quiz-agent",
            audience="quiz-agent-clients",
            access_ttl_seconds=900,
        )
        app.state.rooms = self.service
        app.state.session_manager = self.sessions
        app.state.question_retriever = retriever
        app.state.usage_tracker = usage
        app.state.translation_service = None
        app.state.tts_service = None
        app.state.analytics = events
        self.c = AsyncClient(transport=ASGITransport(app=app), base_url="http://t")


class _Two:
    """Machines A and B (and C for a deploy) of one prod, one game."""

    def __init__(self, db, clock) -> None:
        self.db, self.clock = db, clock
        self.judge, self.usage = Judge(), Usage()
        self.shared = (Retriever([MCQ, OPEN]), self.judge, self.usage, Events())
        self.a, self.b = _Machine(db, self.shared), _Machine(db, self.shared)
        self.room_id = self.session_id = self.token = None

    def machine(self):
        return _Machine(self.db, self.shared)

    async def lobby(self, guests) -> None:
        session = await self.a.sessions.create_session(user_id="host", max_questions=2)
        self.session_id = session.session_id
        r = await self.a.c.post(
            "/api/v1/rooms",
            json={"session_id": session.session_id, "host_name": "Michal"},
            headers=_h("host"),
        )
        assert r.status_code == 200, r.text
        self.room_id, self.token = r.json()["room_id"], r.json()["join_token"]
        for g in guests:
            assert (await self.join(self.a, g)).status_code == 200

    async def start(self) -> None:
        r = await self.a.c.post(
            f"/api/v1/sessions/{self.session_id}/start", json={}, headers=_h("host")
        )
        assert r.status_code == 200, r.text
        r = await self.post(self.a, "open", "host", question_id="q_mcq")
        assert r.status_code == 200, r.text

    async def join(self, m, who):
        return await m.c.post(
            "/api/v1/rooms/join",
            json={"display_name": who.title(), "join_token": self.token},
            headers=_h(who),
        )

    async def post(self, m, path, who, **body):
        return await m.c.post(
            f"/api/v1/rooms/{self.room_id}/{path}", json=body, headers=_h(who)
        )

    async def answer(self, m, who, text):
        return await self.post(m, "answer", who, question_id="q_mcq", answer=text)

    async def state(self, m, who="host"):
        r = await m.c.get(f"/api/v1/rooms/{self.room_id}/state", headers=_h(who))
        assert r.status_code == 200, r.text
        return r.json()

    async def pid(self, who) -> str:
        return (await self.state(self.a, who))["you"]

    async def stored(self):
        return await self.a.sessions.get_session(self.session_id)

    async def race(self, first, second):
        """``first`` runs on A and is parked inside its write, holding the
        lease; ``second`` starts on B and must be seen waiting for that lease
        before A may finish. Returns both responses (first, second)."""
        self.a.store.armed = True
        t1 = asyncio.create_task(first(self.a))
        await asyncio.wait_for(self.a.store.parked.wait(), 10)
        t2 = asyncio.create_task(second(self.b))
        await asyncio.wait_for(self.b.leases.refused.wait(), 10)
        self.a.store.release.set()
        return await asyncio.wait_for(asyncio.gather(t1, t2), 10)


@pytest_asyncio.fixture
async def two(db_sessionmaker, monkeypatch):
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    clock = Clock()
    monkeypatch.setattr(rounds, "now", clock)
    limiter.reset()
    t = _Two(db_sessionmaker, clock)
    yield t
    for m in (t.a, t.b):
        await m.c.aclose()


async def test_two_guests_take_the_last_seat_at_once_one_gets_it(two):
    guests = [f"g{i}" for i in range(MAX_PLAYERS - 2)]
    await two.lobby(guests)  # host + 6 guests: one seat left

    first, second = await two.race(
        lambda m: two.join(m, "late1"), lambda m: two.join(m, "late2")
    )

    assert first.status_code == 200, first.text
    assert second.status_code == 409 and second.json()["detail"] == "The game is full"
    stored = await two.stored()
    assert len(stored.participants) == MAX_PLAYERS
    assert sum(p.user_id == "late2" for p in stored.participants) == 0
    colors = [p.color for p in stored.participants]
    assert len(set(colors)) == len(colors)  # every phone still its own colour


async def test_two_answers_at_the_same_instant_both_count_and_close_once(two):
    await two.lobby(["jana", "peto"])
    await two.start()
    assert (await two.answer(two.a, "host", "a")).status_code == 200

    jana, peto = await two.race(
        lambda m: two.answer(m, "jana", "b"), lambda m: two.answer(m, "peto", "b")
    )

    assert jana.status_code == 200 and peto.status_code == 200
    rnd = (await two.stored()).room_game.current
    assert rnd.closed and set(rnd.answers) == {
        await two.pid("host"),
        await two.pid("jana"),
        await two.pid("peto"),
    }
    # Graded exactly once: one judge call per distinct answer, no regrade.
    assert sorted(two.judge.calls) == ["a", "b"]
    scores = {p.user_id: p.score for p in (await two.stored()).participants}
    assert scores == {"host": 0.0, "jana": 1.0, "peto": 1.0}


async def test_a_last_second_answer_racing_next_is_counted(two):
    """Peto answers as the countdown ends (inside the grace) and the host taps
    next in the same instant: the answer reaches the server first, so it must
    be graded into this question — then next moves on."""
    await two.lobby(["jana", "peto"])
    await two.start()
    for who in ("host", "jana"):
        await two.answer(two.a, who, "b")
    rnd = (await two.stored()).room_game.current
    two.clock.at = rounds.deadline((await two.stored()).room_game, rnd)

    answer, nxt = await two.race(
        lambda m: two.answer(m, "peto", "b"), lambda m: two.post(m, "next", "host")
    )

    assert answer.status_code == 200, answer.text
    assert nxt.status_code == 200, nxt.text
    stored = await two.stored()
    first_round = stored.room_game.rounds[0]
    assert first_round.closed and await two.pid("peto") in first_round.answers
    assert {p.user_id: p.score for p in stored.participants}["peto"] == 1.0
    assert stored.current_question_id == "q_open"  # moved on exactly once
    assert two.usage.used["host"] == 2


async def test_a_late_answer_racing_next_is_refused_never_lost_silently(two):
    """The time is up; the host's next closes the question first. Peto's late
    answer must get a clear refusal, and must not slip into the closed round
    or the next one."""
    await two.lobby(["jana", "peto"])
    await two.start()
    for who in ("host", "jana"):
        await two.answer(two.a, who, "b")
    game = (await two.stored()).room_game
    two.clock.at = rounds.deadline(game, game.current) + rounds.ANSWER_GRACE

    nxt, answer = await two.race(
        lambda m: two.post(m, "next", "host"), lambda m: two.answer(m, "peto", "b")
    )

    assert nxt.status_code == 200, nxt.text
    assert answer.status_code == 409, answer.text
    assert answer.json()["detail"] in ("Not the current question", "Time is up")
    stored = await two.stored()
    peto = await two.pid("peto")
    assert all(peto not in r.answers for r in stored.room_game.rounds)
    assert {p.user_id: p.score for p in stored.participants}["peto"] == 0.0


async def test_removing_a_guest_while_they_answer_never_breaks_the_round(two):
    """The host removes Peto in the same instant Peto answers (answer first):
    the answer that landed stays graded, the removal holds, nothing 500s."""
    await two.lobby(["jana", "peto"])
    await two.start()
    await two.answer(two.a, "host", "b")
    peto = await two.pid("peto")

    answer, removed = await two.race(
        lambda m: two.answer(m, "peto", "b"),
        lambda m: m.c.delete(
            f"/api/v1/rooms/{two.room_id}/players/{peto}", headers=_h("host")
        ),
    )

    assert answer.status_code == 200, answer.text
    assert removed.status_code == 204, removed.text
    stored = await two.stored()
    assert peto not in {p.participant_id for p in stored.participants}
    # Jana still owes her answer; when it comes, the round closes normally.
    last = await two.answer(two.a, "jana", "b")
    assert last.status_code == 200, last.text
    assert (await two.stored()).room_game.current.closed


async def test_a_guest_removed_first_is_told_they_are_out(two):
    await two.lobby(["jana", "peto"])
    await two.start()
    peto = await two.pid("peto")

    removed, answer = await two.race(
        lambda m: m.c.delete(
            f"/api/v1/rooms/{two.room_id}/players/{peto}", headers=_h("host")
        ),
        lambda m: two.answer(m, "peto", "b"),
    )

    assert removed.status_code == 204, removed.text
    assert answer.status_code == 404, answer.text
    rnd = (await two.stored()).room_game.current
    assert peto not in rnd.answers


async def test_a_deploy_mid_question_continues_the_same_game(two):
    """Machine A answers half the room, then a deploy replaces it. The new
    machine reads the game from Postgres: earlier answers stay, the round
    closes when the rest answer, and next moves everyone on."""
    await two.lobby(["jana", "peto"])
    await two.start()
    for who in ("host", "jana"):
        assert (await two.answer(two.a, who, "b")).status_code == 200
    await two.a.c.aclose()

    c = two.machine()
    try:
        last = await two.answer(c, "peto", "a")
        assert last.status_code == 200, last.text
        rnd = last.json()["round"]
        assert rnd["phase"] == "revealed"
        points = {r["participant_id"]: r["points"] for r in rnd["results"]}
        assert points == {
            (await two.state(c, "host"))["you"]: 1.0,
            (await two.state(c, "jana"))["you"]: 1.0,
            (await two.state(c, "peto"))["you"]: 0.0,
        }
        assert (await two.post(c, "next", "host")).status_code == 200
        assert (await two.state(c, "peto"))["round"]["question_id"] == "q_open"
    finally:
        await c.c.aclose()


async def test_a_machine_killed_holding_the_lease_does_not_freeze_the_room(
    two, monkeypatch
):
    """A machine SIGKILLed mid-request never releases the session lease. The
    other machine must take the game over once the lease expires, so the
    players' next taps work instead of hanging until a 503."""
    from app.session import manager as m

    await two.lobby(["jana"])
    await two.start()
    dead = LeaseStore(two.db)
    assert await dead.try_acquire(f"session:{two.session_id}", "killed-machine", 0.5)

    resp = await two.answer(two.b, "jana", "b")

    assert resp.status_code == 200, resp.text
    assert two.b.leases.refused.is_set()  # it did wait for the dead holder
    assert m.SESSION_LEASE_WAIT_S > 0.5
    rnd = (await two.stored()).room_game.current
    assert await two.pid("jana") in rnd.answers


async def test_play_again_on_one_machine_reaches_a_guest_polling_another(two):
    # #240.9: the room row now points at the new session in Postgres, so a
    # guest whose polls land on the other machine sees the new lobby with the
    # same people, and the old link still leads into it.
    await two.lobby(["jana"])
    await two.start()
    for who in ("host", "jana"):
        await two.answer(two.a, who, "b")
    await two.post(two.a, "next", "host")
    await two.post(two.a, "open", "host", question_id="q_open")
    for who in ("host", "jana"):
        await two.post(two.a, "answer", who, question_id="q_open", answer="Paris")
    await two.post(two.a, "next", "host")
    finished = await two.state(two.b, "jana")
    assert finished["status"] == "finished"

    fresh = await two.a.sessions.create_session(user_id="host", max_questions=2)
    moved = await two.a.c.post(
        "/api/v1/rooms",
        json={
            "session_id": fresh.session_id,
            "host_name": "Michal",
            "room_id": two.room_id,
        },
        headers=_h("host"),
    )
    assert moved.status_code == 200, moved.text
    assert moved.json()["join_token"] == two.token

    lobby = await two.state(two.b, "jana")
    assert lobby["status"] == "lobby" and lobby["version"] > finished["version"]
    assert {p["display_name"] for p in lobby["players"]} == {"Michal", "Jana"}
    assert (await two.join(two.b, "peto")).status_code == 200
