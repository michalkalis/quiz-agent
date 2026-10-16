"""#205 daily challenge endpoints: behind the server switch, one attempt per
player per date, and a start hands back an ordinary quiz session that plays the
day's set in order — exempt from the free monthly quota."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
import pytest_asyncio
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.api.routes import daily_challenge as daily_routes
from app.auth.tokens import TokenService
from app.daily_challenge.service import DailyChallengeService
from app.rate_limit import limiter
from app.session.manager import SessionManager

from tests.test_daily_challenge_service import FakeRetriever

pytestmark = pytest.mark.asyncio

_SECRET = "t" * 64


def _tokens() -> TokenService:
    return TokenService(
        secret=_SECRET,
        issuer="quiz-agent",
        audience="quiz-agent-clients",
        access_ttl_seconds=900,
    )


def _bearer(subject="anon-daily") -> dict[str, str]:
    return {"Authorization": f"Bearer {_tokens().create_access_token(subject)}"}


def _today() -> str:
    return datetime.now(timezone.utc).date().isoformat()


@pytest_asyncio.fixture
async def app(db_sessionmaker, monkeypatch):
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(daily_routes.router, prefix="/api/v1")
    app.state.token_service = _tokens()
    app.state.session_manager = SessionManager()
    app.state.daily_challenge = DailyChallengeService(db_sessionmaker, FakeRetriever())
    return app


@pytest_asyncio.fixture
async def client(app):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        yield c


async def test_switch_off_hides_the_endpoints(client, monkeypatch):
    monkeypatch.setenv("DAILY_CHALLENGE_ENABLED", "false")
    resp = await client.get(
        "/api/v1/daily-challenge",
        params={"date": _today(), "language": "en"},
        headers=_bearer(),
    )
    assert resp.status_code == 404


async def test_requires_a_bearer(client):
    resp = await client.get(
        "/api/v1/daily-challenge", params={"date": _today(), "language": "en"}
    )
    assert resp.status_code == 401


async def test_rejects_a_date_that_is_not_today(client):
    old = (datetime.now(timezone.utc).date() - timedelta(days=3)).isoformat()
    resp = await client.post(
        "/api/v1/daily-challenge/start",
        json={"date": old, "language": "en"},
        headers=_bearer(),
    )
    assert resp.status_code == 422


async def test_start_returns_a_quota_exempt_session_with_the_days_set(client, app):
    before = await client.get(
        "/api/v1/daily-challenge",
        params={"date": _today(), "language": "en"},
        headers=_bearer(),
    )
    assert before.json()["status"] == "not_played"

    resp = await client.post(
        "/api/v1/daily-challenge/start",
        json={"date": _today(), "language": "en"},
        headers=_bearer(),
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["state"]["status"] == "in_progress"
    session = await app.state.session_manager.get_session(body["session"]["session_id"])
    assert session.max_questions == 5
    assert session.fixed_question_ids == await app.state.daily_challenge.question_ids(
        "en", datetime.fromisoformat(_today()).date()
    )
    assert session.is_quota_exempt
    assert session.user_id == "anon-daily"


async def test_a_finished_challenge_comes_back_as_its_result(client, app):
    svc = app.state.daily_challenge
    resp = await client.post(
        "/api/v1/daily-challenge/start",
        json={"date": _today(), "language": "en"},
        headers=_bearer(),
    )
    session = await app.state.session_manager.get_session(
        resp.json()["session"]["session_id"]
    )
    for qid in session.fixed_question_ids:
        await svc.record_answer(session, qid, "correct")
    await svc.finish(session)

    again = await client.post(
        "/api/v1/daily-challenge/start",
        json={"date": _today(), "language": "en"},
        headers=_bearer(),
    )
    body = again.json()
    assert body["session"] is None
    assert body["state"]["status"] == "played"
    assert body["state"]["summary"]["score"] == 5
    assert body["state"]["summary"]["comparison"] == "You're first today."
