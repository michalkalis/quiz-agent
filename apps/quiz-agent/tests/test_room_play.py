"""#212.2 answer flow of a multiplayer room.

What matters: every player (the host too) answers the same question against
one server-side clock, the question closes exactly once (everyone answered, or
time is up), each answer is graded by the solo evaluator and lands in that
player's own stats, and only the host's monthly limit is charged (M1).
"""

from __future__ import annotations

import asyncio
from collections import Counter
from datetime import datetime, timedelta, timezone

import pytest
import pytest_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from quiz_shared.models.question import Question
from quiz_shared.utils.text_normalization import normalize_text

from app.api.routes import quiz as quiz_routes
from app.api.routes import room_play as play_routes
from app.api.routes import rooms as room_routes
from app.auth.tokens import TokenService
from app.quiz.flow import QuizFlowService
from app.rate_limit import limiter
from app.rooms import rounds
from app.rooms.network import NetTickets
from app.rooms.play import RoomPlay
from app.rooms.service import RoomService
from app.rooms.store import MemoryRoomStore
from app.session.manager import SessionManager

pytestmark = pytest.mark.asyncio

_SECRET = "p" * 64
IP = "84.245.1.10"
T0 = datetime(2026, 10, 28, 18, 0, tzinfo=timezone.utc)

MCQ = Question(
    id="q_mcq",
    question="Which planet has the most moons?",
    type="text_multichoice",
    correct_answer="b",
    possible_answers={"a": "Jupiter", "b": "Saturn", "c": "Mars", "d": "Venus"},
    topic="space",
    category="science",
    difficulty="medium",
    language="en",
)
OPEN = Question(
    id="q_open",
    question="What is the capital of France?",
    type="text",
    correct_answer="Paris",
    topic="geo",
    category="geography",
    difficulty="easy",
    language="en",
)


class Retriever:
    def __init__(self, questions):
        self.questions = list(questions)

    async def get(self, qid):
        return next((q for q in self.questions if q.id == qid), None)

    async def get_next_question(self, session, client_excluded_ids=None, **_):
        asked = set(session.asked_question_ids)
        return next((q for q in self.questions if q.id not in asked), None)

    async def pack_is_generating(self, pack_id):
        return False


class Judge:
    """Stands in for AnswerEvaluator; records every grading call."""

    def __init__(self):
        self.calls: list[str] = []

    async def evaluate(self, user_answer, question, question_text=""):
        self.calls.append(user_answer)
        await asyncio.sleep(0)
        ok = normalize_text(user_answer) == normalize_text(str(question.correct_answer))
        return ("correct", 1.0) if ok else ("incorrect", 0.0)


class Usage:
    def __init__(self, limit=100):
        self.used: Counter = Counter()
        self.limit = limit

    async def check_limit(self, user_id):
        return self.used[user_id] < self.limit, 0, None

    async def record_question(self, user_id):
        self.used[user_id] += 1

    async def get_usage(self, user_id):
        return {
            "questions_used": self.used[user_id],
            "questions_limit": self.limit,
            "plan": "free",
            "resets_at": None,
        }


class Events:
    def __init__(self):
        self.rows: list[tuple[str, str | None, dict]] = []

    def emit(self, name, *, subject_id=None, session_id=None, properties=None):
        self.rows.append((name, subject_id, properties or {}))


def _h(subject: str) -> dict[str, str]:
    tokens = TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )
    return {
        "Authorization": f"Bearer {tokens.create_access_token(subject)}",
        "Fly-Client-IP": IP,
    }


class Clock:
    def __init__(self):
        self.at = T0

    def __call__(self):
        return self.at

    def tick(self, seconds: float):
        self.at += timedelta(seconds=seconds)


@pytest_asyncio.fixture
async def game(monkeypatch):
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    clock = Clock()
    monkeypatch.setattr(rounds, "now", clock)
    limiter.reset()
    sessions = SessionManager()
    store = MemoryRoomStore()
    retriever, judge, usage, events = Retriever([MCQ, OPEN]), Judge(), Usage(), Events()
    flow = QuizFlowService(
        session_manager=sessions,
        input_parser=None,
        question_retriever=retriever,
        answer_evaluator=judge,
        tts_service=None,
        usage_tracker=usage,
        translation_service=None,
        analytics=events,
    )
    service = RoomService(sessions, store, NetTickets(_SECRET))
    service.play = RoomPlay(sessions, store, flow)
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
    app.state.rooms = service
    app.state.session_manager = sessions
    app.state.question_retriever = retriever
    app.state.usage_tracker = usage
    app.state.translation_service = None
    app.state.tts_service = None
    app.state.analytics = events
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        yield Game(c, sessions, service, judge, usage, events, clock)


class Game:
    def __init__(self, client, sessions, service, judge, usage, events, clock):
        self.c, self.sessions, self.service = client, sessions, service
        self.judge, self.usage, self.events, self.clock = judge, usage, events, clock
        self.room_id = self.session_id = None

    async def setup(
        self, guests=("jana", "peto"), max_questions=2, start=True, **create
    ):
        session = await self.sessions.create_session(
            user_id="host", max_questions=max_questions
        )
        self.session_id = session.session_id
        r = await self.c.post(
            "/api/v1/rooms",
            json={"session_id": session.session_id, "host_name": "Michal", **create},
            headers=_h("host"),
        )
        assert r.status_code == 200, r.text
        self.room_id, token = r.json()["room_id"], r.json()["join_token"]
        for g in guests:
            j = await self.c.post(
                "/api/v1/rooms/join",
                json={"display_name": g.title(), "join_token": token},
                headers=_h(g),
            )
            assert j.status_code == 200, j.text
        if not start:
            return None
        start = await self.c.post(
            f"/api/v1/sessions/{session.session_id}/start", json={}, headers=_h("host")
        )
        assert start.status_code == 200, start.text
        return start.json()

    async def state(self, who="host", since=None):
        params = {"since": since} if since is not None else {}
        r = await self.c.get(
            f"/api/v1/rooms/{self.room_id}/state", params=params, headers=_h(who)
        )
        assert r.status_code == 200, r.text
        return r.json()

    async def post(self, path, who="host", **body):
        return await self.c.post(
            f"/api/v1/rooms/{self.room_id}/{path}", json=body, headers=_h(who)
        )

    async def answer(self, who, qid, text):
        return await self.post("answer", who, question_id=qid, answer=text)

    async def pid(self, who):
        return (await self.state(who))["you"]

    async def settle(self):
        await asyncio.gather(*self.service.play._tasks)


async def test_everyone_answers_the_host_too_and_the_last_answer_reveals(game):
    await game.setup()
    q = (await game.state())["round"]
    assert q["question_id"] == "q_mcq" and q["phase"] == "reading"
    assert "correct_answer" not in (await game.state("jana"))["question"]

    await game.post("open", question_id="q_mcq")
    assert (await game.answer("host", "q_mcq", "a")).status_code == 200
    assert (await game.answer("jana", "q_mcq", "b")).status_code == 200
    mid = (await game.state("peto"))["round"]
    # Who answered is visible, what they answered is not.
    assert mid["phase"] == "answering" and mid.get("results") is None
    assert len(mid["answered"]) == 2

    last = await game.answer("peto", "q_mcq", "b")
    rnd = last.json()["round"]
    assert rnd["phase"] == "revealed" and rnd["correct_answer"] == "Saturn"
    points = {r["participant_id"]: r["points"] for r in rnd["results"]}
    assert points == {
        await game.pid("host"): 0.0,
        await game.pid("jana"): 1.0,
        await game.pid("peto"): 1.0,
    }


async def test_only_the_hosts_limit_is_charged_once_per_question(game):
    # M1: the host pays every served question, guests never pay anything.
    await game.setup(max_questions=2)
    for who in ("host", "jana", "peto"):
        await game.answer(who, "q_mcq", "b")
    assert game.usage.used == Counter({"host": 1})
    await game.post("next")
    for who in ("host", "jana", "peto"):
        await game.answer(who, "q_open", "Paris")
    end = (await game.post("next")).json()
    assert end["status"] == "finished" and end["finished_reason"] == "max_questions"
    assert game.usage.used == Counter({"host": 2})


async def test_equal_answers_are_graded_once(game):
    await game.setup(guests=("jana", "peto", "zuza"))
    for who in ("host", "jana", "peto", "zuza"):
        await game.answer(who, "q_mcq", "b")
    await game.post("next")
    game.judge.calls.clear()
    for who, text in (
        ("host", "Paris"),
        ("jana", " paris "),
        ("peto", "PARIS"),
        ("zuza", "Lyon"),
    ):
        await game.answer(who, "q_open", text)
    # One judge call per distinct answer, not per player.
    assert sorted(normalize_text(c) for c in game.judge.calls) == ["lyon", "paris"]


async def test_time_up_closes_once_and_silence_scores_zero(game):
    await game.setup(thinking_seconds=10)
    await game.post("open", question_id="q_mcq")
    await game.answer("jana", "q_mcq", "b")
    state = await game.state()
    assert state["round"]["remaining_ms"] == 15_000  # 10 s thinking + 5 s

    game.clock.tick(15 + rounds.ANSWER_GRACE.total_seconds())
    late = await game.answer("peto", "q_mcq", "b")
    assert late.status_code == 409
    assert (await game.state())["round"]["phase"] == "grading"
    await game.settle()
    calls = len(game.judge.calls)
    # A second close (another machine, a retried poll) changes nothing.
    await game.service.play._close(game.session_id)
    assert len(game.judge.calls) == calls

    rnd = (await game.state())["round"]
    assert rnd["phase"] == "revealed"
    assert [r["participant_id"] for r in rnd["results"]] == [await game.pid("jana")]
    scores = {p["display_name"]: p["score"] for p in (await game.state())["players"]}
    assert scores == {"Michal": 0.0, "Jana": 1.0, "Peto": 0.0}


async def test_typed_answers_get_more_time_and_the_clock_waits_for_reading(game):
    await game.setup(thinking_seconds=10)
    for who in ("host", "jana", "peto"):
        await game.answer(who, "q_mcq", "b")
    await game.post("next")
    assert "remaining_ms" not in (await game.state())["round"]  # host reads
    game.clock.tick(6)
    await game.post("open", question_id="q_open")
    game.clock.tick(3)
    await game.post("open", question_id="q_open")  # "read again" must not reset
    # 10 s thinking + 5 s to start + 8 s answer + 5 s to type, minus 3 s gone.
    assert (await game.state())["round"]["remaining_ms"] == 25_000


async def test_a_host_phone_that_never_opens_cannot_stall_the_room(game):
    await game.setup()
    game.clock.tick(45)
    rnd = (await game.state("jana"))["round"]
    assert rnd["phase"] == "answering" and rnd["remaining_ms"] == 15_000


async def test_answers_are_final_and_only_the_host_steers(game):
    await game.setup()
    assert (await game.answer("jana", "q_mcq", "a")).status_code == 200
    assert (await game.answer("jana", "q_mcq", "b")).status_code == 409
    assert (await game.answer("jana", "q_other", "b")).status_code == 409
    assert (await game.post("open", "jana", question_id="q_mcq")).status_code == 403
    assert (await game.post("next", "jana")).status_code == 403
    assert (await game.post("next")).status_code == 409  # still answering
    assert (await game.answer("stranger", "q_mcq", "b")).status_code == 404


async def test_unchanged_poll_is_tiny_while_answering(game):
    await game.setup()
    await game.post("open", question_id="q_mcq")
    v = (await game.state("jana"))["version"]
    assert (await game.state("jana", since=v))["changed"] is False


async def test_each_answer_is_logged_under_the_player_who_gave_it(game):
    await game.setup()
    for who in ("host", "jana", "peto"):
        await game.answer(who, "q_mcq", "b")
    rows = [r for r in game.events.rows if r[0] == "answer_evaluated"]
    assert sorted(r[1] for r in rows) == ["host", "jana", "peto"]
    assert all(r[2]["multiplayer"] is True for r in rows)
    assert {r[2]["room_id"] for r in rows} == {game.room_id}


async def test_only_the_host_sees_who_left_the_app_and_only_at_the_end(game):
    await game.setup(max_questions=1)
    await game.post("away", "peto", question_id="q_mcq")
    await game.post("away", "peto", question_id="q_mcq")  # counted once
    assert "away" not in await game.state()  # not during the game
    for who in ("host", "jana", "peto"):
        await game.answer(who, "q_mcq", "b")
    await game.post("next")
    host_end, guest_end = await game.state(), await game.state("jana")
    assert host_end["away"] == [
        {"participant_id": await game.pid("peto"), "questions": 1}
    ]
    assert "away" not in guest_end
    # No penalty: Peto's correct answer still counts.
    assert {p["display_name"]: p["score"] for p in host_end["players"]}["Peto"] == 1.0


async def test_ranking_breaks_a_tie_by_speed(game):
    await game.setup(max_questions=1)
    await game.post("open", question_id="q_mcq")
    game.clock.tick(1)
    await game.answer("peto", "q_mcq", "b")
    game.clock.tick(4)
    await game.answer("jana", "q_mcq", "b")
    await game.answer("host", "q_mcq", "c")
    end = (await game.post("next")).json()
    names = {p["participant_id"]: p["display_name"] for p in end["players"]}
    assert [names[r["participant_id"]] for r in end["ranking"]] == [
        "Peto",
        "Jana",
        "Michal",
    ]
    assert [r["number"] for r in end["rounds"]] == [1]


async def test_the_hosts_empty_limit_ends_the_game_like_solo(game):
    game.usage.limit = 1
    await game.setup()
    for who in ("host", "jana", "peto"):
        await game.answer(who, "q_mcq", "b")
    end = (await game.post("next")).json()
    assert end["status"] == "finished" and end["finished_reason"] == "usage_limit"
    assert game.usage.used == Counter({"host": 1})


async def test_a_guest_deleting_their_account_takes_their_answers(game):
    await game.setup()
    jana = await game.pid("jana")
    await game.answer("jana", "q_mcq", "b")
    await game.sessions.forget_user("jana")
    rnd = (await game.state())["round"]
    assert jana not in rnd["answered"]


async def test_picture_questions_are_off_in_a_room(game):
    await game.setup()
    session = await game.sessions.get_session(game.session_id)
    assert session.include_images is False


async def test_rules_set_in_the_lobby_reach_every_phone_and_only_the_host_sets_them(
    game,
):
    # #213.8: guests see the host's rules before the game; nobody else may
    # change them, or a guest could cut everyone's answer time.
    await game.setup(start=False)
    r = await game.post(
        "settings", reveal_mode="round", thinking_seconds=30, reads_aloud=False
    )
    assert r.status_code == 200, r.text
    jana = await game.state("jana")
    assert (jana["reveal_mode"], jana["thinking_seconds"], jana["reads_aloud"]) == (
        "round",
        30,
        False,
    )
    assert (await game.post("settings", "jana", thinking_seconds=3)).status_code == 403
    assert (await game.post("settings", thinking_seconds=90)).status_code == 422


async def test_answer_time_changes_from_the_next_question_and_reveal_stays(game):
    # #213.8: a change mid-question must not cut or stretch the clock players
    # already see; how answers show cannot flip halfway through a game.
    await game.setup(thinking_seconds=10)
    await game.post("open", question_id="q_mcq")
    assert (await game.post("settings", thinking_seconds=30)).status_code == 200
    assert (await game.state())["round"]["remaining_ms"] == 15_000  # 10 s + 5 s
    assert (await game.post("settings", reveal_mode="round")).status_code == 409
    assert (await game.post("settings", reveal_mode="question")).status_code == 200
    for who in ("host", "jana", "peto"):
        await game.answer(who, "q_mcq", "b")
    await game.post("next")
    await game.post("open", question_id="q_open")
    assert (await game.state())["round"]["remaining_ms"] == 48_000  # 30 s + 18 s
