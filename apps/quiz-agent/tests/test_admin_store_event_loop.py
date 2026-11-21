"""Admin question routes must await the async store on the serving loop.

Production bug: `POST /questions/set-category` returned 500 "Future attached to
a different loop". The routes called a sync facade that ran the store's async
calls on a private background loop, while the store's pooled DB connections
belong to the loop the server runs on. Every admin question route had the same
shape. These tests wire a store whose async calls only work on the loop that
created it (like asyncpg connections), so any route that hops loops fails.
"""

from __future__ import annotations

import asyncio

import pytest
import pytest_asyncio
from app.api import admin as admin_routes
from app.rate_limit import limiter
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from quiz_shared.database.sync_pgvector_store import SyncPgvectorStore
from quiz_shared.models.question import Question
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

pytestmark = pytest.mark.asyncio

_KEY = "super-secret-admin-key"
_QID = "11111111-1111-1111-1111-111111111111"
_H = {"X-Admin-Key": _KEY}


class _LoopBoundStore:
    """Async store whose calls fail off the loop it was created on."""

    def __init__(self) -> None:
        self._loop = asyncio.get_running_loop()
        self._items = {
            _QID: Question(
                id=_QID,
                question="Q?",
                correct_answer="a",
                topic="Space",
                category="general",
                difficulty="medium",
                review_status="approved",
                embedding=[0.5] * 4,
                embedding_model="text-embedding-3-small",
                embedding_dim=4,
            )
        }

    async def _on_loop(self) -> None:
        await asyncio.sleep(0)
        if asyncio.get_running_loop() is not self._loop:
            raise RuntimeError("Future attached to a different loop")

    async def get(self, question_id):
        await self._on_loop()
        q = self._items.get(question_id)
        return q.model_copy(deep=True) if q else None

    async def upsert(self, question):
        await self._on_loop()
        self._items[question.id] = question
        return True

    async def add(self, question):
        await self._on_loop()
        self._items[question.id] = question
        return True

    async def delete(self, question_id):
        await self._on_loop()
        return self._items.pop(question_id, None) is not None

    async def get_all(self, limit=1000):
        await self._on_loop()
        return list(self._items.values())

    async def find_duplicates(self, text, threshold=0.85):
        await self._on_loop()
        return []


@pytest_asyncio.fixture
async def client(monkeypatch):
    monkeypatch.setenv("ADMIN_API_KEY", _KEY)
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
    app.include_router(admin_routes.router)
    app.state.question_store = _LoopBoundStore()
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c


async def test_sync_facade_is_what_breaks_on_a_loop_bound_store():
    """Root cause pinned: the sync facade hops to its own loop, so a store
    bound to the serving loop rejects it. Admin routes must never use it."""
    facade = SyncPgvectorStore(_LoopBoundStore())
    with pytest.raises(RuntimeError, match="different loop"):
        facade.get(_QID)


async def test_set_category_runs_on_serving_loop(client):
    """Corpus recategorization is the call that 500'd in production."""
    r = await client.post(
        "/api/v1/admin/questions/set-category",
        json={"assignments": [{"id": _QID, "category": "history"}]},
        headers=_H,
    )
    assert r.status_code == 200 and r.json()["updated_count"] == 1


async def test_review_status_runs_on_serving_loop(client):
    """Archiving a weak batch must not 500 on the same loop hop."""
    r = await client.post(
        "/api/v1/admin/questions/review-status",
        json={"ids": [_QID], "status": "archived"},
        headers=_H,
    )
    assert r.status_code == 200 and r.json()["updated_count"] == 1


async def test_backfill_sources_runs_on_serving_loop(client):
    """Source attribution backfill reads then writes through the same store."""
    r = await client.post(
        "/api/v1/admin/questions/backfill-sources",
        json={"items": [{"id": _QID, "source_url": "https://example.org/x"}]},
        headers=_H,
    )
    assert r.status_code == 200 and r.json()["updated_count"] == 1


async def test_import_runs_on_serving_loop(client):
    """Importing new questions is how the corpus grows; it uses get + add."""
    r = await client.post(
        "/api/v1/admin/questions/import",
        json={
            "questions": [
                {
                    "id": "q-new-1",
                    "question": "New?",
                    "correct_answer": "a",
                    "topic": "Space",
                    "category": "general",
                    "difficulty": "medium",
                    "source_url": "https://example.org/x",
                }
            ],
            "force": True,
        },
        headers=_H,
    )
    assert r.status_code == 200 and r.json()["imported_count"] == 1


async def test_list_runs_on_serving_loop(client):
    """Curators browse the corpus through this listing."""
    r = await client.get("/api/v1/admin/questions", headers=_H)
    assert r.status_code == 200 and r.json()["total"] == 1


async def test_stats_runs_on_serving_loop(client):
    """Corpus statistics read the whole store."""
    r = await client.get("/api/v1/admin/questions/stats", headers=_H)
    assert r.status_code == 200 and r.json()["total_questions"] == 1


async def test_delete_runs_on_serving_loop(client):
    """Deleting reads then deletes; both must stay on the serving loop."""
    r = await client.delete(f"/api/v1/admin/questions/{_QID}", headers=_H)
    assert r.status_code == 200
    listing = await client.get("/api/v1/admin/questions", headers=_H)
    assert listing.json()["total"] == 0
