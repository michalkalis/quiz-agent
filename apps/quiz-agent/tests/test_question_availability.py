"""#174 finding 1 — ``POST /questions/availability`` must not lie about the corpus.

A quiz configured for 10 questions ended after 3: the retriever ran out of
unseen questions and the flow silently finished the session. The app now asks
this endpoint first and offers a shorter set (or a history reset) instead of
promising a length the corpus cannot deliver.

That only helps if the number is the number the retriever would actually serve,
so these tests pin the *eligibility*, not the arithmetic: the same category /
language / review-status / pack_id constraints the serve path uses, minus the
seen history, minus the one key (`difficulty`) the retriever's own fallback
relaxes before giving up.
"""

from __future__ import annotations

import inspect
from unittest.mock import AsyncMock, MagicMock

import pytest
import pytest_asyncio
from fastapi import FastAPI
from fastapi.params import Depends as DependsParam
from httpx import ASGITransport, AsyncClient
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.api import deps
from app.api.routes import misc as misc_routes
from app.auth.tokens import TokenError
from app.rate_limit import limiter
from app.retrieval.question_retriever import QuestionRetriever

pytestmark = pytest.mark.asyncio

SUBJECT = "subject-a"


class _FakeTokenService:
    """Decodes a bearer whose token IS the subject id; anything else is invalid."""

    def decode_access_token(self, token: str) -> dict:
        if token != SUBJECT:
            raise TokenError("bad token")
        return {"sub": token}


@pytest.fixture(autouse=True)
def _no_rate_limit(monkeypatch):
    monkeypatch.setattr(limiter, "enabled", False)


@pytest.fixture
def store() -> MagicMock:
    s = MagicMock()
    s.count = AsyncMock(return_value=0)
    return s


@pytest.fixture
def app(store: MagicMock) -> FastAPI:
    application = FastAPI()
    application.state.limiter = limiter
    application.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    application.include_router(misc_routes.router, prefix="/api/v1")
    # A real retriever over a mock store: the filter construction under test is
    # the retriever's, so mocking the retriever would test nothing.
    application.dependency_overrides.update(
        {
            deps.get_question_retriever: lambda: QuestionRetriever(
                question_store=store
            ),
            deps.get_token_service: _FakeTokenService,
        }
    )
    return application


@pytest_asyncio.fixture
async def client(app: FastAPI):
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c


def _auth() -> dict:
    return {"Authorization": f"Bearer {SUBJECT}"}


async def _ask(client: AsyncClient, headers: dict | None = None, **body):
    payload = {"requested_count": 10, "difficulty": "medium", "language": "en"}
    payload.update(body)
    return await client.post(
        "/api/v1/questions/availability",
        json=payload,
        headers={**_auth(), **(headers or {})},
    )


async def test_reports_shortfall_so_the_client_can_offer_a_shorter_set(client, store):
    """WHY: the founder asked for 10 and got 3 — the shortfall must be visible
    BEFORE the quiz starts, with the honest number to fall back to."""
    store.count.return_value = 3

    response = await _ask(client, requested_count=10)

    assert response.status_code == 200
    assert response.json() == {"available": 3, "requested": 10, "sufficient": False}


async def test_zero_available_is_a_normal_answer_not_an_error(client, store):
    """WHY: the exhausted case is exactly when the client must show the alert;
    a 4xx/5xx here would collapse into the app's generic network error."""
    store.count.return_value = 0

    response = await _ask(client, requested_count=10)

    assert response.status_code == 200
    assert response.json()["available"] == 0
    assert response.json()["sufficient"] is False


async def test_enough_questions_reports_sufficient(client, store):
    """WHY: the happy path must stay silent — no alert when the corpus can
    actually deliver the requested length."""
    store.count.return_value = 42

    response = await _ask(client, requested_count=10)

    assert response.json() == {"available": 42, "requested": 10, "sufficient": True}


async def test_count_excludes_the_history_the_client_sends(client, store):
    """WHY: the whole bug is 'unseen' — counting the full corpus would report
    plenty while the retriever, which excludes seen ids, has nothing left."""
    await _ask(client, excluded_question_ids=["q-1", "q-2", "q-3"])

    kwargs = store.count.await_args.kwargs
    assert set(kwargs["excluded_ids"]) == {"q-1", "q-2", "q-3"}


async def test_non_english_session_excludes_language_dependent_questions(client, store):
    """WHY: the Slovak quiz that exposed this is served the #128 filter; a count
    that ignored it would over-report by every wordplay question."""
    await _ask(client, language="sk")

    filters = store.count.await_args.kwargs["filters"]
    assert filters["language_dependent"] is False


async def test_english_session_keeps_language_dependent_questions(client, store):
    """WHY: the mirror of the above — the filter is a non-English constraint, so
    an English count that applied it would under-report and alert needlessly."""
    await _ask(client, language="en")

    assert "language_dependent" not in store.count.await_args.kwargs["filters"]


async def test_category_selection_narrows_the_count(client, store):
    """WHY: the founder's session was category-scoped ('general'); a count over
    all categories would have said 'plenty' for a category that was empty."""
    await _ask(client, categories=["science", "history"])

    filters = store.count.await_args.kwargs["filters"]
    assert filters["category"] == {"$in": ["science", "history"]}


async def test_legacy_single_category_field_still_narrows_the_count(client, store):
    """WHY: pre-#82 clients send `category`, not `categories`; session creation
    maps it into the retriever filter, and this probe must agree with it."""
    await _ask(client, category="music")

    filters = store.count.await_args.kwargs["filters"]
    assert filters["category"] == {"$in": ["music"]}


async def test_count_ignores_difficulty_because_the_retriever_relaxes_it(client, store):
    """WHY: `_fallback_retrieval` step 3 drops difficulty before giving up, so a
    difficulty-pinned count would refuse a quiz the retriever could have served."""
    await _ask(client, difficulty="hard")

    assert "difficulty" not in store.count.await_args.kwargs["filters"]


async def test_count_keeps_the_serve_path_constraints(client, store):
    """WHY: this must be the *served* eligibility, not a hand-rolled copy — the
    curated-corpus (pack_id IS NULL) and review gates travel with it, and only
    rows the retriever can return (embedded, unexpired) may be counted."""
    await _ask(client)

    kwargs = store.count.await_args.kwargs
    assert kwargs["filters"]["review_status"] == "approved"
    assert kwargs["filters"]["pack_id"] is None
    assert kwargs["servable_only"] is True


async def test_testflight_channel_counts_pending_review_too(client, store):
    """WHY: TestFlight installs are served pending_review questions (founder,
    2026-08-28), so a count without them would alert on a corpus they can play."""
    await _ask(client, headers={"X-Build-Channel": "testflight"})

    statuses = store.count.await_args.kwargs["filters"]["review_status"]
    assert statuses == {"$in": ["approved", "pending_review"]}


async def test_route_declares_the_shared_auth_dependency():
    """WHY: structural, not behavioural — ``LEGACY_USER_ID_GRACE`` still lets
    bearer-less calls through, so the only durable guard against this becoming
    an open corpus enumerator is that it goes through the same gate (#65) every
    other cost-bearing endpoint does, and keeps going through it after a
    refactor."""
    endpoint = next(
        route.endpoint
        for route in misc_routes.router.routes
        if getattr(route, "path", "") == "/questions/availability"
    )
    declares_auth = any(
        isinstance(param.default, DependsParam)
        and param.default.dependency is deps.require_auth_or_grace
        for param in inspect.signature(inspect.unwrap(endpoint)).parameters.values()
    )
    assert declares_auth
