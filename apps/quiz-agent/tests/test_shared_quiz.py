"""#232 share a quiz by link — the endpoints against the real schema.

Why these matter: the link is a door into someone else's quiz, so it must never
widen what a player can get. The list is built by the server from the sender's
own session (a client cannot inject ids), the friend's own serving rules apply
again at play time (a TestFlight-only question never reaches an App Store
friend), a shared pack is played once per person and never unlocks the pack
itself, and the free quota is not charged. Results are one per person so
replaying cannot skew the comparison. Everything hides behind a DB switch.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
import pytest_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from quiz_shared.models.phase import SessionPhase

from app import app_switches
from app.api.routes import shared_quiz as share_routes
from app.auth.tokens import TokenService
from app.daily_challenge.service import DailyChallengeService
from app.db.models import AnonymousIdentity
from app.rate_limit import limiter
from app.session.manager import SessionManager
from app.shared_quiz.service import SharedQuizService
from app.shared_quiz.store import SharedQuizStore

from tests.test_daily_challenge_service import FakeRetriever as DailyRetriever

pytestmark = pytest.mark.asyncio

_SECRET = "s" * 64
PENDING = "q-pending"
PACK = "11111111-1111-1111-1111-111111111111"


def _tokens() -> TokenService:
    return TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )


def _h(subject: str, testflight: bool = False) -> dict[str, str]:
    headers = {"Authorization": f"Bearer {_tokens().create_access_token(subject)}"}
    if testflight:
        headers["X-Build-Channel"] = "testflight"
    return headers


class FakeRetriever(DailyRetriever):
    """Corpus rows q0..q11 (approved), one TestFlight-only row and pack rows.
    The real SQL of these filters is pinned in tests/db/test_shared_quiz_filters.py;
    here they only need to answer the way the serving rules do."""

    def __init__(self):
        super().__init__()
        self.status = {q.id: "approved" for q in self.pool}
        self.status[PENDING] = "pending_review"
        self.pack = {"p1": PACK, "p2": PACK, "p-rejected": PACK}
        self.status.update({"p1": "pending_review", "p2": "pending_review"})
        self.status["p-rejected"] = "rejected"

    async def shared_question(self, session, qid):
        status = self.status.get(qid)
        if status is None:
            return None
        if session.pack_id:
            ok = self.pack.get(qid) == session.pack_id and status not in (
                "rejected",
                "archived",
            )
        else:
            allowed = {"approved"}
            if session.build_channel == "testflight":
                allowed.add("pending_review")
            ok = qid not in self.pack and status in allowed
        return SimpleNamespace(id=qid, language="en") if ok else None

    async def pack_question_ids(self, pack_id, limit=500):
        return [
            q
            for q, p in self.pack.items()
            if p == pack_id and self.status[q] not in ("rejected", "archived")
        ]


class FakeStore(SharedQuizStore):
    """Pack ownership lives in quiz-pack-api's ``question_packs``; the real
    SQL is the session gate's (tests/db/test_pack_ownership.py)."""

    packs: dict = {}

    async def owned_pack(self, pack_id, subject_id):
        pack = self.packs.get(pack_id)
        return pack if pack and pack["owner"] == subject_id else None


@pytest_asyncio.fixture
async def app(db_sessionmaker, monkeypatch):
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    limiter.reset()
    app_switches.reset_cache()
    await app_switches.write(db_sessionmaker, {"shared_quiz_enabled": True}, [])
    retriever = FakeRetriever()
    sessions = SessionManager()
    daily = DailyChallengeService(db_sessionmaker, retriever)
    FakeStore.packs = {
        PACK: {
            "owner": "owner",
            "name": "Techno",
            "language": "sk",
            "status": "complete",
        }
    }
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(share_routes.router, prefix="/api/v1")
    app.state.token_service = _tokens()
    app.state.auth_sessionmaker = db_sessionmaker
    app.state.session_manager = sessions
    app.state.shared_quiz = SharedQuizService(
        FakeStore(db_sessionmaker), sessions, retriever, daily
    )
    yield app
    app_switches.reset_cache()


@pytest_asyncio.fixture
async def client(app):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        yield c


async def _finished(app, subject, asked, score=2.0, **fields):
    sessions = app.state.session_manager
    session = await sessions.create_session(user_id=subject, max_questions=len(asked))
    session.asked_question_ids = list(asked)
    session.participants[0].score = score
    session.phase = SessionPhase.FINISHED
    for key, value in fields.items():
        setattr(session, key, value)
    await sessions.update_session(session)
    return session


async def _share(client, subject, **body):
    resp = await client.post("/api/v1/shared-quizzes", json=body, headers=_h(subject))
    assert resp.status_code == 200, resp.text
    return resp.json()


async def _start(client, token, subject, **kw):
    testflight = kw.pop("testflight", False)
    return await client.post(
        f"/api/v1/shared-quizzes/{token}/start",
        json=kw,
        headers=_h(subject, testflight),
    )


async def _session(app, resp):
    sid = resp.json()["session"]["session_id"]
    return await app.state.session_manager.get_session(sid)


async def _finish(app, session, score):
    session.asked_question_ids = list(session.fixed_question_ids)
    session.participants[0].score = score
    session.phase = SessionPhase.FINISHED
    await app.state.shared_quiz.finish(session)


async def test_switch_off_hides_every_endpoint(client, app, db_sessionmaker):
    await app_switches.write(db_sessionmaker, {"shared_quiz_enabled": False}, [])
    for method, path in [
        ("post", "/api/v1/shared-quizzes"),
        ("post", "/api/v1/shared-quizzes/abcdefgh/start"),
        ("get", "/api/v1/shared-quizzes/abcdefgh/results"),
        ("get", "/api/v1/shared-quizzes/abcdefgh"),
    ]:
        resp = await getattr(client, method)(
            path, **({"json": {}} if method == "post" else {}), headers=_h("a")
        )
        assert resp.status_code == 404, path


async def test_list_comes_from_the_senders_session_not_the_request(client, app):
    session = await _finished(app, "sender", ["q1", "q2", PENDING, "q3"])
    # A client trying to slip its own ids in: unknown body keys are ignored.
    share = await _share(
        client, "sender", session_id=session.session_id, question_ids=["p1", "q9"]
    )
    stored = await app.state.shared_quiz.store.by_token(share["token"])
    # The TestFlight-only row the sender got is not carried to anyone.
    assert stored.question_ids == ["q1", "q2", "q3"]
    assert share["kind"] == "round" and share["question_count"] == 3
    assert "question_ids" not in share
    # Sharing the same quiz again gives the same link.
    again = await _share(client, "sender", session_id=session.session_id)
    assert again["token"] == share["token"]


async def test_only_the_owner_shares_and_only_a_finished_quiz(client, app):
    session = await _finished(app, "sender", ["q1"])
    resp = await client.post(
        "/api/v1/shared-quizzes",
        json={"session_id": session.session_id},
        headers=_h("stranger"),
    )
    assert resp.status_code == 404
    session.phase = SessionPhase.ASKING
    await app.state.session_manager.update_session(session)
    resp = await client.post(
        "/api/v1/shared-quizzes",
        json={"session_id": session.session_id},
        headers=_h("sender"),
    )
    assert resp.status_code == 409


async def test_friend_gets_a_quota_free_session_refiltered_by_their_build(client, app):
    session = await _finished(app, "sender", ["q1", "q2", "q3"])
    token = (await _share(client, "sender", session_id=session.session_id))["token"]
    # Rejected after the link was made: the friend's own filters drop it.
    app.state.shared_quiz.retriever.status["q2"] = "pending_review"
    store_build = await _session(app, await _start(client, token, "friend"))
    assert store_build.fixed_question_ids == ["q1", "q3"]
    assert store_build.max_questions == 2
    assert store_build.is_quota_exempt and not store_build.is_solo_only
    assert store_build.user_id == "friend" and store_build.language == "en"
    beta = await _session(app, await _start(client, token, "tester", testflight=True))
    assert beta.fixed_question_ids == ["q1", "q2", "q3"]


async def test_results_one_per_person_with_player_numbers(client, app, db_sessionmaker):
    session = await _finished(app, "sender", ["q1", "q2", "q3"], score=2.0)
    token = (
        await _share(
            client, "sender", session_id=session.session_id, display_name="Mia"
        )
    )["token"]
    friend = await _session(app, await _start(client, token, "anon-friend"))
    await _finish(app, friend, 3.0)
    # The same person signed in later and replays: the first result stands.
    async with db_sessionmaker() as db:
        db.add(AnonymousIdentity(anon_id="anon-friend", upgraded_to_user_id="acct"))
        await db.commit()
    again = await _session(app, await _start(client, token, "acct"))
    await _finish(app, again, 0.0)
    other = await _session(app, await _start(client, token, "other"))
    await _finish(app, other, 1.0)

    resp = await client.get(
        f"/api/v1/shared-quizzes/{token}/results", headers=_h("acct")
    )
    assert resp.status_code == 200
    players = resp.json()["players"]
    assert [(p["name"], p["score"]) for p in players] == [
        ("Player 1", 3.0),
        ("Mia", 2.0),
        ("Player 2", 1.0),
    ]
    assert [p["is_you"] for p in players] == [True, False, False]
    assert players[1]["is_sender"]


async def test_pack_link_plays_once_per_person_and_only_that_pack(client, app):
    share = await _share(client, "owner", pack_id=PACK)
    assert share["kind"] == "pack" and share["title"] == "Techno"
    assert share["language"] == "sk" and share["question_count"] == 2
    resp = await _start(client, share["token"], "friend")
    session = await _session(app, resp)
    assert session.pack_id == PACK and session.fixed_question_ids == ["p1", "p2"]
    assert session.is_quota_exempt and session.is_solo_only
    # Once per person: starting it again is refused.
    assert (await _start(client, share["token"], "friend")).status_code == 409
    # The owner never "plays once" their own pack through the link.
    assert (await _start(client, share["token"], "owner")).status_code == 409


async def test_only_the_owner_shares_a_pack_and_only_when_finished(client, app):
    resp = await client.post(
        "/api/v1/shared-quizzes", json={"pack_id": PACK}, headers=_h("friend")
    )
    assert resp.status_code == 404
    FakeStore.packs[PACK]["status"] = "generating"
    resp = await client.post(
        "/api/v1/shared-quizzes", json={"pack_id": PACK}, headers=_h("owner")
    )
    assert resp.status_code == 409


async def _daily_share(client, app, day):
    set_ids = await app.state.shared_quiz.daily.question_ids("en", day)
    session = await _finished(
        app, "sender", set_ids, daily_challenge_date=day.isoformat()
    )
    token = (await _share(client, "sender", session_id=session.session_id))["token"]
    return token, set_ids


async def test_daily_link_opened_today_is_the_friends_own_challenge(client, app):
    """No date from the app: the server decides, so today's five never run as
    a round beside the crowd numbers ("better than X %")."""
    today = datetime.now(timezone.utc).date()
    token, set_ids = await _daily_share(client, app, today)
    # Even a stale date in the body is not a lever any more (field is gone).
    resp = await _start(client, token, "friend", date="2026-01-01")
    played = await _session(app, resp)
    assert played.daily_challenge_date == today.isoformat()
    assert played.fixed_question_ids == set_ids and played.is_solo_only
    play, _ = await app.state.shared_quiz.daily.begin("friend", "en", today)
    assert play.session_id == played.session_id  # it is their attempt


async def test_daily_link_of_a_closed_day_plays_as_a_round(client, app):
    old = datetime.now(timezone.utc).date() - timedelta(days=3)
    token, set_ids = await _daily_share(client, app, old)
    late = await _session(app, await _start(client, token, "late"))
    assert late.daily_challenge_date is None and late.fixed_question_ids == set_ids


async def test_daily_link_after_playing_today_in_another_language(client, app):
    today = datetime.now(timezone.utc).date()
    token, _ = await _daily_share(client, app, today)
    await app.state.shared_quiz.daily.begin("friend", "sk", today)
    resp = await _start(client, token, "friend")
    assert resp.status_code == 409
    assert resp.json()["detail"]["code"] == "daily_played_other_language"


async def test_daily_already_played_today_still_lands_in_the_ranking(client, app):
    today = datetime.now(timezone.utc).date()
    daily = app.state.shared_quiz.daily
    set_ids = await daily.question_ids("en", today)
    session = await _finished(
        app, "sender", set_ids, daily_challenge_date=today.isoformat()
    )
    token = (await _share(client, "sender", session_id=session.session_id))["token"]
    play, remaining = await daily.begin("friend", "en", today)
    own = await _finished(app, "friend", [], daily_challenge_date=today.isoformat())
    await daily.attach_session(play.id, own.session_id)
    for qid in remaining:
        await daily.record_answer(own, qid, "correct")
    await daily.finish(own)

    resp = await _start(client, token, "friend")
    assert resp.json() == {"kind": "daily", "session": None, "already_played": True}
    ranking = await client.get(
        f"/api/v1/shared-quizzes/{token}/results", headers=_h("friend")
    )
    assert [p["score"] for p in ranking.json()["players"]] == [5.0, 2.0]


async def test_public_preview_shows_no_questions_and_needs_no_login(client, app):
    session = await _finished(app, "sender", ["q1"], preferred_categories=["music"])
    token = (await _share(client, "sender", session_id=session.session_id))["token"]
    resp = await client.get(f"/api/v1/shared-quizzes/{token}")
    assert resp.status_code == 200
    assert resp.json() == {
        "kind": "round",
        "language": "en",
        "title": None,
        "categories": ["music"],
    }
    assert (await client.get("/api/v1/shared-quizzes/unknown-token")).status_code == 404
