"""Tests for the QuestionStorage pending-store front (#41: ChromaDB retired).

QuestionStorage now fronts ONLY the pre-approval `PendingStore` — approved
questions live in pgvector and are written by the order pipeline, never by
this service. These tests pin that contract: imports land as pending, edits
stay in pending, and nothing here can promote a question to "approved".

Uses `InMemoryPendingStore` so the test stays hermetic — no on-disk state.
"""

from __future__ import annotations

import pytest

from quiz_shared.database.pending_store import InMemoryPendingStore
from quiz_shared.models.question import Question

from app.generation.storage import QuestionStorage


def _make_question(qid: str = "q_001", **overrides) -> Question:
    defaults = dict(
        id=qid,
        question="What is 2+2?",
        correct_answer="4",
        topic="Math",
        category="adults",
        difficulty="easy",
        review_status="pending_review",
    )
    defaults.update(overrides)
    return Question(**defaults)


@pytest.fixture
def storage() -> QuestionStorage:
    return QuestionStorage(pending_store=InMemoryPendingStore())


def test_add_pending_lands_in_pending_store(storage: QuestionStorage):
    q = _make_question()
    assert storage.add_pending(q) is True
    assert storage.get_question(q.id) is not None
    assert [p.id for p in storage.list_pending()] == [q.id]


def test_add_pending_normalizes_status(storage: QuestionStorage):
    """An imported question marked 'approved' must still land as pending —
    with the Chroma approve path retired, nothing in this service may mint
    approved rows (that is the future #42/#30 pgvector flow's job)."""
    q = _make_question(review_status="approved")
    storage.add_pending(q)
    fetched = storage.pending.get(q.id)
    assert fetched.review_status == "pending_review"


def test_add_pending_replaces_temp_id(storage: QuestionStorage):
    q = _make_question(qid="temp_xyz")
    storage.add_pending(q)
    assert q.id.startswith("q_")
    assert q.id != "temp_xyz"
    assert storage.pending.get(q.id) is not None


def test_update_question_persists_reviewer_edits(storage: QuestionStorage):
    q = _make_question(review_status="needs_revision")
    storage.pending.upsert(q)
    q.review_notes = "fixed wording"
    assert storage.update_question(q) is True
    assert storage.pending.get(q.id).review_notes == "fixed wording"


def test_update_question_upserts_unseen_row(storage: QuestionStorage):
    """The review-then-save flow may hit update before the row exists —
    it must land in pending rather than being dropped."""
    q = _make_question(qid="q_fresh")
    assert storage.update_question(q) is True
    assert storage.pending.get("q_fresh") is not None


def test_delete_question_removes_pending_row(storage: QuestionStorage):
    q = _make_question(qid="q_pending")
    storage.pending.upsert(q)
    assert storage.delete_question("q_pending") is True
    assert storage.pending.get("q_pending") is None
    assert storage.delete_question("q_pending") is False


def test_search_filters_by_review_status(storage: QuestionStorage):
    storage.pending.upsert(_make_question(qid="p1", review_status="pending_review"))
    storage.pending.upsert(_make_question(qid="p2", review_status="pending_review"))
    storage.pending.upsert(_make_question(qid="r1", review_status="needs_revision"))

    results = storage.search_questions(filters={"review_status": "pending_review"}, limit=10)
    assert sorted(q.id for q in results) == ["p1", "p2"]


def test_search_applies_scalar_filters(storage: QuestionStorage):
    storage.pending.upsert(_make_question(qid="e1", difficulty="easy"))
    storage.pending.upsert(_make_question(qid="h1", difficulty="hard"))

    results = storage.search_questions(difficulty="hard", limit=10)
    assert [q.id for q in results] == ["h1"]


def test_get_all_returns_every_pending_status(storage: QuestionStorage):
    """Stats pages aggregate over ALL pending-store rows (any status) —
    a default status filter here would silently undercount."""
    storage.pending.upsert(_make_question(qid="p1", review_status="pending_review"))
    storage.pending.upsert(_make_question(qid="r1", review_status="needs_revision"))

    ids = {q.id for q in storage.get_all_questions()}
    assert ids == {"p1", "r1"}
