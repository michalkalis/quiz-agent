"""#239 the daily crew: a weekly table of everyone a player swapped a daily
link with, by rarity points.

Why these matter: the table shows a name and a score to other people, so who
is in it must follow exactly the links the player made (never friends of
friends), a removal must hide both sides for good, and one person must stay
one row through a sign-in. The points must reward knowing what few knew, and
only this week's finished challenges count.
"""

from __future__ import annotations

import secrets
import uuid
from datetime import date, datetime, timedelta, timezone

import pytest
import pytest_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.api.routes import daily_challenge as daily_routes
from app.auth.account_service import _erase_personal_trail
from app.auth.tokens import TokenService
from app.daily_challenge.crew import CrewNotFound, DailyCrewService, week_start
from app.daily_challenge.rules import rarity_points
from app.daily_challenge.service import DailyChallengeService
from app.db.models import (
    AnonymousIdentity,
    DailyChallengeAnswer,
    DailyChallengePlay,
    DailyCrewRemoval,
    SharedQuiz,
    SharedQuizResult,
)
from app.rate_limit import limiter
from app.session.manager import SessionManager

from tests.test_daily_challenge_service import FakeRetriever

pytestmark = pytest.mark.asyncio

# A Wednesday, so the week has days before and after it.
DAY = date(2026, 11, 18)
NOW = datetime(2026, 11, 18, 12, tzinfo=timezone.utc)


def test_rarity_points_reward_what_few_knew():
    assert rarity_points(1, 1) == 10  # alone: the common points, no windfall
    assert rarity_points(4, 4) == 10  # everyone knew it
    assert rarity_points(2, 1) == 55
    assert rarity_points(10, 1) == 91  # few knew it: close to the top
    assert rarity_points(0, 0) == 10


def test_week_starts_on_monday():
    assert week_start(DAY) == date(2026, 11, 16)
    assert week_start(date(2026, 11, 16)) == date(2026, 11, 16)
    assert week_start(date(2026, 11, 22)) == date(2026, 11, 16)


async def _link(sm, sender, friend, *, sender_name=None, friend_name=None, at=NOW):
    """``friend`` opened ``sender``'s daily link. The member id is the row."""
    async with sm() as db:
        share = SharedQuiz(
            id=uuid.uuid4(),
            token=secrets.token_urlsafe(8),
            kind="daily",
            language="en",
            question_ids=["q0"],
            challenge_date=at.date(),
            source_session_id=secrets.token_hex(4),
            sender_subject_id=sender,
            sender_name=sender_name,
            created_at=at,
        )
        db.add(share)
        await db.flush()
        result = SharedQuizResult(
            id=uuid.uuid4(),
            shared_quiz_id=share.id,
            subject_id=friend,
            display_name=friend_name,
            started_at=at,
        )
        db.add(result)
        await db.commit()
        return str(result.id)


async def _played(sm, subject, day, knew, *, finished=True):
    """A daily play with one answer per entry of ``knew`` (q0, q1, …)."""
    async with sm() as db:
        play = DailyChallengePlay(
            id=uuid.uuid4(),
            subject_id=subject,
            challenge_date=day,
            language="en",
            started_at=NOW,
            finished_at=NOW if finished else None,
            score=sum(knew),
        )
        db.add(play)
        await db.flush()
        for i, k in enumerate(knew):
            db.add(
                DailyChallengeAnswer(
                    play_id=play.id,
                    question_id=f"q{i}",
                    result="correct" if k else "incorrect",
                    knew=k,
                )
            )
        await db.commit()


def _rows(crew):
    return [(m.name, m.points, m.place, m.is_you) for m in crew.members]


async def test_no_crew_without_a_daily_link(db_sessionmaker):
    """A table of one would be noise; the app explains how a crew forms."""
    await _played(db_sessionmaker, "ana", DAY, [True])
    crew = await DailyCrewService(db_sessionmaker).crew("ana", DAY, "sk")
    assert crew.members == [] and crew.week_start == "2026-11-16"


async def test_both_directions_count_but_never_friends_of_friends(db_sessionmaker):
    sm = db_sessionmaker
    await _link(sm, "ana", "ben", sender_name="Ana", friend_name="Ben")
    await _link(sm, "cid", "ana", sender_name="Cid", friend_name="Ana")
    svc = DailyCrewService(sm)

    ana = await svc.crew("ana", DAY, "en")
    ben = await svc.crew("ben", DAY, "en")
    assert sorted(m.name for m in ana.members if not m.is_you) == ["Ben", "Cid"]
    # Ben and Cid never swapped a link: neither sees the other.
    assert [m.name for m in ben.members if not m.is_you] == ["Ana"]


async def test_points_are_rarity_points_from_monday_to_the_day(db_sessionmaker):
    sm = db_sessionmaker
    await _link(sm, "ana", "ben", sender_name="Ana", friend_name="Ben")
    # Today: q0 only Ana knew (2 answered, 1 knew → 55), q1 both knew (10 each).
    await _played(sm, "ana", DAY, [True, True])
    await _played(sm, "ben", DAY, [False, True])
    # Monday counts; last Sunday and an unfinished play do not.
    await _played(sm, "ben", date(2026, 11, 16), [True])
    await _played(sm, "ben", date(2026, 11, 15), [True, True, True])
    await _played(sm, "ana", date(2026, 11, 17), [True], finished=False)

    crew = await DailyCrewService(sm).crew("ana", DAY, "en")
    assert _rows(crew) == [(None, 65, 1, True), ("Ben", 20, 2, False)]
    you, ben = crew.members
    assert (you.today, you.days) == (65, 1)
    assert (ben.today, ben.days) == (10, 2)


async def test_equal_points_share_the_place(db_sessionmaker):
    sm = db_sessionmaker
    await _link(sm, "ana", "ben", friend_name="Ben")
    await _played(sm, "ana", DAY, [True])
    await _played(sm, "ben", DAY, [True])
    crew = await DailyCrewService(sm).crew("ana", DAY, "en")
    assert [m.place for m in crew.members] == [1, 1]


async def test_one_person_through_a_sign_in_is_one_row(db_sessionmaker):
    """Ben opened the link as an anon, then signed in and played under his
    account: still one row, with the account's points."""
    sm = db_sessionmaker
    async with sm() as db:
        db.add(AnonymousIdentity(anon_id="ben-anon", upgraded_to_user_id="ben-user"))
        await db.commit()
    await _link(sm, "ana", "ben-anon", friend_name="Ben")
    await _link(sm, "ben-user", "ana", sender_name="Benny", at=NOW + timedelta(hours=1))
    await _played(sm, "ben-user", DAY, [True])
    crew = await DailyCrewService(sm).crew("ana", DAY, "en")
    others = [m for m in crew.members if not m.is_you]
    assert [(m.name, m.points) for m in others] == [("Benny", 10)]  # newest name


async def test_only_this_weeks_crew_is_listed(db_sessionmaker):
    """A link from weeks ago with no play this week drops off the table."""
    sm = db_sessionmaker
    old = NOW - timedelta(days=14)
    await _link(sm, "ana", "old", friend_name="Old", at=old)
    await _link(sm, "ana", "back", friend_name="Back", at=old)
    await _played(sm, "back", DAY, [True])
    crew = await DailyCrewService(sm).crew("ana", DAY, "en")
    assert [m.name for m in crew.members if not m.is_you] == ["Back"]


async def test_a_name_is_never_empty(db_sessionmaker):
    await _link(db_sessionmaker, "ana", "ben")
    crew = await DailyCrewService(db_sessionmaker).crew("ana", DAY, "sk")
    assert [m.name for m in crew.members if not m.is_you] == ["Hráč 1"]


async def test_removal_hides_both_sides_even_after_a_new_link(db_sessionmaker):
    sm = db_sessionmaker
    member = await _link(sm, "ana", "ben", sender_name="Ana", friend_name="Ben")
    svc = DailyCrewService(sm)
    await svc.remove("ana", member)

    assert (await svc.crew("ana", DAY, "en")).members == []
    assert (await svc.crew("ben", DAY, "en")).members == []
    await _link(sm, "ben", "ana", sender_name="Ben", at=NOW + timedelta(hours=1))
    assert (await svc.crew("ana", DAY, "en")).members == []
    assert (await svc.crew("ben", DAY, "en")).members == []


async def test_removing_works_only_on_your_own_links(db_sessionmaker):
    sm = db_sessionmaker
    theirs = await _link(sm, "ben", "cid")
    svc = DailyCrewService(sm)
    for member_id in (theirs, str(uuid.uuid4()), "not-a-uuid"):
        with pytest.raises(CrewNotFound):
            await svc.remove("ana", member_id)


async def test_deleting_your_data_deletes_removals_both_ways(db_sessionmaker):
    sm = db_sessionmaker
    await DailyCrewService(sm).remove("ana", await _link(sm, "ana", "ben"))
    await DailyCrewService(sm).remove("cid", await _link(sm, "cid", "ana"))
    async with sm() as db:
        await _erase_personal_trail(db, ["ana"])
        await db.commit()
    async with sm() as db:
        assert (await db.execute(DailyCrewRemoval.__table__.select())).all() == []


# ── endpoints ─────────────────────────────────────────────────────────────
_SECRET = "c" * 64


def _tokens() -> TokenService:
    return TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )


def _bearer(subject: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {_tokens().create_access_token(subject)}"}


@pytest_asyncio.fixture
async def client(db_sessionmaker, monkeypatch):
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(daily_routes.router, prefix="/api/v1")
    app.state.token_service = _tokens()
    app.state.session_manager = SessionManager()
    app.state.daily_challenge = DailyChallengeService(db_sessionmaker, FakeRetriever())
    app.state.daily_crew = DailyCrewService(db_sessionmaker)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        yield c


async def test_crew_endpoints_list_and_remove(client, db_sessionmaker):
    today = datetime.now(timezone.utc)
    member = await _link(db_sessionmaker, "ana", "ben", friend_name="Ben", at=today)
    params = {"date": today.date().isoformat(), "language": "en"}

    listed = await client.get(
        "/api/v1/daily-challenge/crew", params=params, headers=_bearer("ana")
    )
    assert listed.status_code == 200
    rows = listed.json()["members"]
    assert [(m["name"], m["member_id"]) for m in rows if not m["is_you"]] == [
        ("Ben", member)
    ]

    removed = await client.delete(
        f"/api/v1/daily-challenge/crew/{member}", headers=_bearer("ana")
    )
    assert removed.status_code == 204
    again = await client.delete(
        f"/api/v1/daily-challenge/crew/{uuid.uuid4()}", headers=_bearer("ana")
    )
    assert again.status_code == 404
    after = await client.get(
        "/api/v1/daily-challenge/crew", params=params, headers=_bearer("ana")
    )
    assert after.json()["members"] == []


async def test_crew_is_behind_the_daily_switch(client, monkeypatch):
    """A store build before the launch never sees anyone's name or score."""
    monkeypatch.setenv("DAILY_CHALLENGE_ENABLED", "false")
    params = {"date": datetime.now(timezone.utc).date().isoformat(), "language": "en"}
    resp = await client.get(
        "/api/v1/daily-challenge/crew", params=params, headers=_bearer("ana")
    )
    assert resp.status_code == 404
