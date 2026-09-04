"""POST /api/v1/admin/questions/import — what review_status an import stamps.

Founder rule (2026-08-28, reaffirmed 2026-09-04, CONTEXT.md "Review status ×
build channel"): `approved` means *a human vouched for this question* and makes
it servable to every client, App Store included. The endpoint used to hardcode
`review_status="approved"` on every imported row, so any agent or script with
the admin key could push machine-generated questions straight into App Store
serving without a human ever seeing them.

These pins encode the rule, not the mechanics: the default must be the
non-serving `pending_review`, and `approved` must be reachable only when the
caller says so explicitly (the human-gated promotion path).
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


def _payload(qid: str = "q-import-1", **overrides) -> dict:
    question = {
        "id": qid,
        "question": f"Question {qid}?",
        "correct_answer": "answer",
        "topic": "General",
        "category": "general",
        "difficulty": "medium",
    }
    question.update(overrides)
    return {"questions": [question], "force": True}


class _FakeStore:
    """In-memory stand-in for the pgvector store (get + find_duplicates + add)."""

    def __init__(self) -> None:
        self.added: list[Question] = []

    def get(self, question_id: str) -> Question | None:
        return None

    def find_duplicates(self, text: str, threshold: float = 0.85):
        return []

    def add(self, question: Question) -> bool:
        self.added.append(question)
        return True


@pytest_asyncio.fixture
async def store() -> _FakeStore:
    return _FakeStore()


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


async def _post(client, body: dict):
    return await client.post(
        "/api/v1/admin/questions/import",
        json=body,
        headers={"X-Admin-Key": _ADMIN_KEY},
    )


async def test_import_defaults_to_pending_review(client, store):
    """No human has seen an imported batch, so it must not reach App Store
    clients: `pending_review` keeps it TestFlight-only."""
    response = await _post(client, _payload())

    assert response.status_code == 200
    assert response.json()["imported_count"] == 1
    assert store.added[0].review_status == "pending_review"


async def test_explicit_approved_is_honoured(client, store):
    """Promotion after a human verdict still has to work — the founder's
    rating flow imports already-reviewed rows as `approved`."""
    response = await _post(client, _payload(review_status="approved"))

    assert response.status_code == 200
    assert store.added[0].review_status == "approved"


async def test_non_review_statuses_are_rejected(client, store):
    """`archived` / `rejected` belong to the curation seam
    (POST /questions/review-status), not to an import: accepting them here
    would let a caller write serving state this endpoint does not own."""
    response = await _post(client, _payload(review_status="archived"))

    assert response.status_code == 422
    assert store.added == []
