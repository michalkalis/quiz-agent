"""POST /api/v1/admin/questions/set-category — corpus recategorization.

Why this endpoint exists: the category filter the app exposes is only useful
if it matches what the corpus actually holds (the 2026-08 revamp found six of
eight picker categories with zero approved questions). Curation therefore
needs a bulk way to move questions onto the interest taxonomy without
re-importing — and, like the review-status flip, it must reuse the stored
embedding (a category change is not a content change).
"""

from __future__ import annotations

import pytest
import pytest_asyncio
from app.api import admin as admin_routes
from app.rate_limit import limiter
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from quiz_shared.models.question import Question
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

pytestmark = pytest.mark.asyncio

_ADMIN_KEY = "super-secret-admin-key"
_QID = "11111111-1111-1111-1111-111111111111"


def _question(qid: str, category: str = "general") -> Question:
    return Question(
        id=qid,
        question=f"Question {qid}?",
        correct_answer="answer",
        topic="Space",
        category=category,
        difficulty="medium",
        review_status="approved",
        embedding=[0.5] * 4,
        embedding_model="text-embedding-3-small",
        embedding_dim=4,
    )


class _FakeStore:
    """In-memory stand-in for the pgvector store (get + upsert only)."""

    def __init__(self, questions: list[Question]) -> None:
        self._items: dict[str, Question] = {q.id: q for q in questions}
        self.upserted: list[Question] = []

    def get(self, question_id: str) -> Question | None:
        stored = self._items.get(question_id)
        return stored.model_copy(deep=True) if stored else None

    def upsert(self, question: Question) -> bool:
        self._items[question.id] = question
        self.upserted.append(question)
        return True

    def category_of(self, question_id: str) -> str:
        return self._items[question_id].category


@pytest_asyncio.fixture
async def store() -> _FakeStore:
    return _FakeStore([_question(_QID)])


@pytest_asyncio.fixture
async def client(store, monkeypatch):
    monkeypatch.setenv("ADMIN_API_KEY", _ADMIN_KEY)
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(admin_routes.router)
    app.state.question_store = store
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def _post(client, body: dict, key: str = _ADMIN_KEY):
    return await client.post(
        "/api/v1/admin/questions/set-category",
        json=body,
        headers={"X-Admin-Key": key},
    )


async def test_assignment_moves_question_to_taxonomy_category(client, store):
    """The whole point: after the call the question filters under its new
    interest category on the read path."""
    response = await _post(
        client, {"assignments": [{"id": _QID, "category": "science-nature"}]}
    )

    assert response.status_code == 200
    assert response.json()["updated_count"] == 1
    assert store.category_of(_QID) == "science-nature"


async def test_category_change_reuses_the_existing_embedding(client, store):
    """A category change is not a content change: re-embedding would cost
    money per question and rewrite the vector the corpus is searched by."""
    await _post(client, {"assignments": [{"id": _QID, "category": "history"}]})

    assert store.upserted[0].embedding == [0.5] * 4


async def test_same_category_is_counted_unchanged_not_rewritten(client, store):
    """Re-running the same migration must be a no-op so a retry after a
    partial failure can't churn already-migrated rows."""
    await _post(client, {"assignments": [{"id": _QID, "category": "sports"}]})
    store.upserted.clear()

    response = await _post(
        client, {"assignments": [{"id": _QID, "category": "sports"}]}
    )

    assert response.json()["unchanged_count"] == 1
    assert store.upserted == []


async def test_unknown_id_is_reported_not_fatal(client, store):
    """A stale ID in a big migration batch must not abort the rest."""
    response = await _post(
        client,
        {
            "assignments": [
                {"id": "does-not-exist", "category": "history"},
                {"id": _QID, "category": "history"},
            ]
        },
    )

    body = response.json()
    assert body["not_found_ids"] == ["does-not-exist"]
    assert body["updated_count"] == 1


async def test_category_outside_taxonomy_is_rejected(client, store):
    """The endpoint is the enforcement point of the six-category taxonomy —
    letting arbitrary strings through would recreate the picker/corpus drift
    this revamp removed."""
    response = await _post(
        client, {"assignments": [{"id": _QID, "category": "disney"}]}
    )

    assert response.status_code == 422
    assert store.category_of(_QID) == "general"


async def test_wrong_admin_key_cannot_recategorize(client, store):
    response = await _post(
        client,
        {"assignments": [{"id": _QID, "category": "history"}]},
        key="wrong",
    )

    assert response.status_code == 401
    assert store.category_of(_QID) == "general"
