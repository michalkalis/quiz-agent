"""POST /api/v1/admin/questions/review-status — corpus curation by status flip.

Why this endpoint exists: retiring a weak generation batch must be reversible
and non-destructive. The voice read path serves only `review_status ==
"approved"`, so flipping a batch to "archived" takes it out of play while the
rows (and their embeddings, provenance, created_at) stay intact — and the same
call with "approved" puts the batch back.

The pins below encode that intent: the flip must reach the store, it must not
re-embed (a status change is not a content change, and re-embedding would both
cost money and rewrite the vector), and the two generation-review statuses
("rejected"/"needs_revision") must stay out of this seam — they belong to the
review flow, not to serving.
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


def _question(qid: str, status: str = "approved") -> Question:
    return Question(
        id=qid,
        question=f"Question {qid}?",
        correct_answer="answer",
        topic="General",
        category="general",
        difficulty="medium",
        review_status=status,
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

    def status_of(self, question_id: str) -> str:
        return self._items[question_id].review_status


@pytest_asyncio.fixture
async def store() -> _FakeStore:
    return _FakeStore(
        [
            _question("11111111-1111-1111-1111-111111111111"),
            _question("22222222-2222-2222-2222-222222222222"),
        ]
    )


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
        "/api/v1/admin/questions/review-status",
        json=body,
        headers={"X-Admin-Key": key},
    )


async def test_archiving_takes_questions_out_of_serving(client, store):
    """The whole point: after the flip the rows no longer match the read
    path's `review_status == "approved"` filter."""
    ids = [
        "11111111-1111-1111-1111-111111111111",
        "22222222-2222-2222-2222-222222222222",
    ]
    response = await _post(client, {"ids": ids, "status": "archived"})

    assert response.status_code == 200
    assert response.json()["updated_count"] == 2
    assert all(store.status_of(qid) == "archived" for qid in ids)


async def test_archived_batch_can_be_restored(client, store):
    """Archiving is a retirement, not a deletion — the rollback must work."""
    qid = "11111111-1111-1111-1111-111111111111"
    await _post(client, {"ids": [qid], "status": "archived"})

    response = await _post(client, {"ids": [qid], "status": "approved"})

    assert response.json()["updated_count"] == 1
    assert store.status_of(qid) == "approved"


async def test_status_flip_reuses_the_existing_embedding(client, store):
    """A status change is not a content change: re-embedding would cost money
    per question and rewrite the vector the corpus is searched by."""
    qid = "11111111-1111-1111-1111-111111111111"

    await _post(client, {"ids": [qid], "status": "archived"})

    assert store.upserted[0].embedding == [0.5] * 4


async def test_already_archived_is_counted_unchanged_not_rewritten(client, store):
    """Re-running the same archive call must be a no-op, so a retry after a
    partial failure can't churn rows that are already retired."""
    qid = "11111111-1111-1111-1111-111111111111"
    await _post(client, {"ids": [qid], "status": "archived"})
    store.upserted.clear()

    response = await _post(client, {"ids": [qid], "status": "archived"})

    assert response.json()["unchanged_count"] == 1
    assert store.upserted == []


async def test_unknown_id_is_reported_not_fatal(client, store):
    """A stale ID in a big batch must not abort the rest of the archive run."""
    known = "11111111-1111-1111-1111-111111111111"
    response = await _post(
        client, {"ids": ["does-not-exist", known], "status": "archived"}
    )

    body = response.json()
    assert body["not_found_ids"] == ["does-not-exist"]
    assert body["updated_count"] == 1
    assert store.status_of(known) == "archived"


async def test_review_flow_statuses_are_rejected(client, store):
    """This seam is for serving, not for the generation review flow — letting
    admin set `rejected`/`needs_revision` here would fork that workflow."""
    response = await _post(
        client,
        {"ids": ["11111111-1111-1111-1111-111111111111"], "status": "rejected"},
    )

    assert response.status_code == 422


async def test_empty_id_list_rejected(client):
    """An empty batch is always a caller bug — better a 422 than a silent 0."""
    response = await _post(client, {"ids": [], "status": "archived"})

    assert response.status_code == 422


async def test_wrong_admin_key_cannot_archive(client, store):
    response = await _post(
        client,
        {"ids": ["11111111-1111-1111-1111-111111111111"], "status": "archived"},
        key="wrong",
    )

    assert response.status_code == 401
    assert store.status_of("11111111-1111-1111-1111-111111111111") == "approved"
