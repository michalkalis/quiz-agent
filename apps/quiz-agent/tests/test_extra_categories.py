"""#242 — the server catalog of rotating extra categories (plan
docs/issues/issue-242-extra-categories-rotation.md, step 242.3).

Why these tests matter:
- The list is the only thing that decides what a player is offered: a
  category must never show outside its dates, before anyone scheduled it, or
  with a thin pool that would run dry in two rounds (MIN_QUESTIONS).
- A player who played a category through must hear "you played it all", not
  silently get repeats or the library-wide history-reset offer: extra
  categories are a rotation, so a repeat would be the one thing they promise
  not to be.
- The date and the switch are injected; nothing here sleeps or reads a clock.
"""

from __future__ import annotations

from datetime import date
from unittest.mock import AsyncMock, MagicMock

import pytest
import pytest_asyncio
from app import app_switches, extra_categories
from app.api import deps
from app.api.routes import extra_categories as extra_routes
from app.api.routes import misc as misc_routes
from app.extra_categories import MIN_QUESTIONS, ExtraCategory, catalog_entries
from app.rate_limit import limiter
from app.session.manager import SessionManager
from fastapi import FastAPI, HTTPException
from httpx import ASGITransport, AsyncClient
from quiz_shared.models.question import Question
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from tests.test_family_mode import _create, _Req, _start

pytestmark = pytest.mark.asyncio

TODAY = date(2026, 12, 10)
NAMES = {"sk": "Techno", "en": "Techno"}
KEY = "extra-techno"
ENOUGH = {(KEY,): MIN_QUESTIONS}


def _catalog(monkeypatch, starts=date(2026, 12, 1), until=date(2026, 12, 31)):
    entry = ExtraCategory(KEY, NAMES, starts, until)
    monkeypatch.setattr(extra_categories, "CATALOG", (entry,))
    monkeypatch.setattr(extra_categories, "utc_today", lambda: TODAY)
    monkeypatch.setattr(extra_routes, "utc_today", lambda: TODAY)


def _switch(monkeypatch, on: bool):
    async def _overrides(_sessionmaker):
        return {"extra_categories_enabled": "true" if on else "false"}

    monkeypatch.setattr(app_switches, "cached_overrides", _overrides)


@pytest.fixture(autouse=True)
def _isolated(monkeypatch):
    monkeypatch.setattr(limiter, "enabled", False)

    async def _anon(request, user_id, token_service, sessionmaker):
        from app.auth.identity import AuthSubject

        return AuthSubject(subject_id="u1", is_legacy=False, authenticated=True)

    monkeypatch.setattr("app.api.routes.sessions.resolve_session_subject", _anon)
    app_switches.reset_cache()
    extra_categories.reset_cache()
    yield
    app_switches.reset_cache()
    extra_categories.reset_cache()


# ── The list ────────────────────────────────────────────────────────────────


@pytest.fixture
def retriever():
    r = MagicMock()
    r.extra_category_counts = AsyncMock(return_value=ENOUGH)
    return r


@pytest_asyncio.fixture
async def client(retriever):
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(extra_routes.router, prefix="/api/v1")
    app.dependency_overrides[deps.get_question_retriever] = lambda: retriever
    app.dependency_overrides[deps.get_auth_sessionmaker] = lambda: None
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        yield c


async def _list(client, language="sk", **headers):
    return (
        await client.get(
            "/api/v1/categories/extra", params={"language": language}, headers=headers
        )
    ).json()["categories"]


async def test_offered_inside_window_with_name_and_last_day(client, monkeypatch):
    _catalog(monkeypatch)
    _switch(monkeypatch, True)
    assert await _list(client) == [
        {"key": KEY, "name": "Techno", "until": "2026-12-31"}
    ]


@pytest.mark.parametrize(
    "starts,until",
    [(date(2027, 1, 1), date(2027, 1, 31)), (date(2026, 11, 1), date(2026, 12, 9))],
    ids=["not started", "rotated out"],
)
async def test_outside_window_is_hidden(client, monkeypatch, starts, until):
    """A category past its last day must vanish without a deploy of content."""
    _catalog(monkeypatch, starts, until)
    _switch(monkeypatch, True)
    assert await _list(client) == []


async def test_window_days_are_inclusive():
    entry = ExtraCategory(KEY, NAMES, date(2026, 12, 1), date(2026, 12, 31))
    assert extra_categories.in_window(entry, date(2026, 12, 1))
    assert extra_categories.in_window(entry, date(2026, 12, 31))


async def test_no_window_means_not_scheduled(client, monkeypatch):
    """The catalog ships before the content: an entry nobody scheduled stays dark."""
    _catalog(monkeypatch, None, None)
    _switch(monkeypatch, True)
    assert await _list(client) == []


async def test_below_minimum_is_hidden_exactly_at_minimum_shown(monkeypatch):
    """A thin pool would run dry within a couple of rounds."""
    _catalog(monkeypatch)
    assert catalog_entries("en", {(KEY,): MIN_QUESTIONS - 1}, TODAY) == []
    assert catalog_entries("en", ENOUGH, TODAY) == [
        {"key": KEY, "name": "Techno", "until": "2026-12-31"}
    ]


async def test_language_without_a_name_is_hidden_and_never_counted(
    client, monkeypatch, retriever
):
    _catalog(monkeypatch)
    _switch(monkeypatch, True)
    assert await _list(client, "uk") == []
    assert await _list(client, "xx") == []
    retriever.extra_category_counts.assert_not_awaited()


async def test_switch_off_is_an_empty_list(client, monkeypatch, retriever):
    _catalog(monkeypatch)
    _switch(monkeypatch, False)
    assert await _list(client) == []
    retriever.extra_category_counts.assert_not_awaited()


async def test_channel_is_passed_to_the_count(client, monkeypatch, retriever):
    """Beta counts pending rows, App Store approved only; the SQL itself is
    pinned in tests/db/test_extra_category_isolation.py."""
    _catalog(monkeypatch)
    _switch(monkeypatch, True)
    await _list(client)
    await _list(client, **{"X-Build-Channel": "testflight"})
    assert [c.args[1] for c in retriever.extra_category_counts.await_args_list] == [
        None,
        "testflight",
    ]


# ── Session creation and start ──────────────────────────────────────────────


def _start_retriever(question, count=100):
    r = MagicMock()
    r.get_next_question = AsyncMock(return_value=question)
    r.pack_is_generating = AsyncMock(return_value=False)
    r.count = AsyncMock(return_value=count)
    return r


def _q(category):
    return Question(
        id="q1",
        question="Čo?",
        type="text",
        correct_answer="To",
        topic="t",
        category=category,
        difficulty="easy",
        language="sk",
    )


async def test_extra_key_not_on_offer_is_refused_at_creation(monkeypatch):
    """A rotated-out key (or a closed switch) must not start a quiz that serves
    a category the catalog no longer promises."""
    manager = SessionManager()
    _catalog(monkeypatch, date(2026, 11, 1), date(2026, 12, 9))
    _switch(monkeypatch, True)
    for categories in (["extra-techno"], ["science", "extra-techno"]):
        with pytest.raises(HTTPException) as exc:
            await _create(manager, language="sk", categories=categories)
        assert exc.value.status_code == 400
        assert exc.value.detail["code"] == "extra_category_invalid"

    _catalog(monkeypatch)
    _switch(monkeypatch, False)
    with pytest.raises(HTTPException) as exc:
        await _create(manager, language="sk", categories=["extra-techno"])
    assert exc.value.detail["code"] == "extra_category_invalid"

    _switch(monkeypatch, True)
    assert (await _create(manager, language="sk", categories=[KEY])).session_id


async def test_permanent_categories_ignore_the_extra_switch(monkeypatch):
    _switch(monkeypatch, False)
    created = await _create(SessionManager(), categories=["science"])
    assert created.session_id


async def test_played_out_extra_category_is_409_and_never_a_repeat(monkeypatch):
    _catalog(monkeypatch)
    _switch(monkeypatch, True)
    manager = SessionManager()
    created = await _create(manager, language="sk", categories=[KEY])
    # 95 of 100 known questions in the player's history would trigger the
    # library-wide "reset history" 409 for an ordinary quiz.
    retriever = _start_retriever(None)
    with pytest.raises(HTTPException) as exc:
        await _start(manager, created.session_id, retriever, ["x"] * 95)
    assert exc.value.status_code == 409
    assert exc.value.detail["code"] == "extra_category_exhausted"
    assert "suggestion" not in exc.value.detail
    retriever.count.assert_not_awaited()


async def test_mixed_request_still_starts_while_anything_is_unplayed(monkeypatch):
    _catalog(monkeypatch)
    _switch(monkeypatch, True)
    manager = SessionManager()
    created = await _create(manager, language="sk", categories=["science", KEY])
    started = await _start(
        manager, created.session_id, _start_retriever(_q("science")), []
    )
    assert started.current_question.id == "q1"


async def test_ordinary_quiz_keeps_its_reset_offer(monkeypatch):
    """The extra-only branch must not swallow the existing history-reset 409."""
    _switch(monkeypatch, True)
    manager = SessionManager()
    created = await _create(manager, categories=["science"])
    with pytest.raises(HTTPException) as exc:
        await _start(manager, created.session_id, _start_retriever(None), ["x"] * 90)
    assert exc.value.detail["suggestion"] == "reset_history"


# ── Availability pre-check ──────────────────────────────────────────────────


async def test_availability_of_played_out_extra_category_is_the_coded_end(
    monkeypatch,
):
    """The pre-check is where the app offers a shorter set or a history reset;
    an extra-only request with nothing left must get the coded end instead."""
    from app.auth.identity import AuthSubject
    from app.retrieval.question_retriever import QuestionRetriever

    _catalog(monkeypatch)
    _switch(monkeypatch, True)
    store = MagicMock()
    store.count = AsyncMock(return_value=0)
    body = misc_routes.QuestionAvailabilityRequest(
        requested_count=10, language="sk", categories=[KEY]
    )
    subject = AuthSubject(subject_id="u1", is_legacy=False, authenticated=True)

    with pytest.raises(HTTPException) as exc:
        await misc_routes.get_question_availability(
            request=_Req(),
            body=body,
            question_retriever=QuestionRetriever(question_store=store),
            usage_tracker=None,
            subject=subject,
            auth_sessionmaker=None,
        )
    assert exc.value.detail["code"] == "extra_category_exhausted"

    # Some left: the honest shorter set, no error.
    store.count.return_value = 4
    out = await misc_routes.get_question_availability(
        request=_Req(),
        body=body,
        question_retriever=QuestionRetriever(question_store=store),
        usage_tracker=None,
        subject=subject,
        auth_sessionmaker=None,
    )
    assert (out.available, out.sufficient) == (4, False)
