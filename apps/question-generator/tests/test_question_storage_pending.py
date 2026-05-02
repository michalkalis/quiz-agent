"""Tests for the QuestionStorage orchestrator's pending → approved flow.

Uses `InMemoryPendingStore` and a fake ChromaDB client so the test stays
hermetic — no on-disk state, no embedding API calls.
"""

from __future__ import annotations

from typing import Dict, List, Optional, Tuple

import pytest

from quiz_shared.database.pending_store import InMemoryPendingStore
from quiz_shared.models.question import Question

from app.generation.storage import QuestionStorage


class FakeChromaClient:
    """Minimal stand-in for ChromaDBClient.

    Only implements the methods QuestionStorage actually calls, plus a
    duplicate hook the test toggles to assert duplicate-detection paths.
    """

    def __init__(self):
        self._approved: Dict[str, Question] = {}
        self.duplicate_hits: List[Tuple[Question, float]] = []

    def add_question(self, question: Question) -> bool:
        self._approved[question.id] = question
        return True

    def get_question(self, question_id: str) -> Optional[Question]:
        return self._approved.get(question_id)

    def update_question_obj(self, question: Question) -> bool:
        self._approved[question.id] = question
        return True

    def update_question(self, question_id: str, updates: dict) -> bool:
        existing = self._approved.get(question_id)
        if existing is None:
            return False
        for k, v in updates.items():
            setattr(existing, k, v)
        return True

    def delete_question(self, question_id: str) -> bool:
        return self._approved.pop(question_id, None) is not None

    def find_duplicates(self, question_text: str, threshold: float = 0.85):
        return list(self.duplicate_hits)

    def search_questions(self, query_text=None, filters=None, n_results=10):
        results = list(self._approved.values())
        if filters:
            for k, v in filters.items():
                results = [q for q in results if getattr(q, k, None) == v]
        return results[:n_results]

    def get_all_questions(self, limit: int = 1000):
        return list(self._approved.values())[:limit]


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
    return QuestionStorage(
        chroma_client=FakeChromaClient(),
        pending_store=InMemoryPendingStore(),
    )


def test_add_pending_lands_in_pending_store_only(storage: QuestionStorage):
    q = _make_question()
    assert storage.add_pending(q) is True
    # Fetched via the orchestrator
    assert storage.get_question(q.id) is not None
    # Not in chroma
    assert storage.chroma.get_question(q.id) is None
    # Visible in pending list
    assert [p.id for p in storage.list_pending()] == [q.id]


def test_add_pending_normalizes_status(storage: QuestionStorage):
    """An imported question marked 'approved' should still land as pending."""
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


def test_approve_promotes_pending_to_chroma_and_deletes(storage: QuestionStorage):
    q = _make_question()
    storage.add_pending(q)

    success, error, dups = storage.approve_question(q, force=True)
    assert success is True
    assert error is None
    # Now in chroma…
    assert storage.chroma.get_question(q.id) is not None
    # …and gone from pending
    assert storage.pending.get(q.id) is None
    # status set to approved
    assert q.review_status == "approved"


def test_approve_with_duplicate_blocks_promotion(storage: QuestionStorage):
    q = _make_question()
    storage.add_pending(q)
    similar = _make_question(qid="q_similar", question="What is 2 + 2?")
    storage.chroma.duplicate_hits = [(similar, 0.92)]

    success, error, dups = storage.approve_question(q, force=False)
    assert success is False
    assert error == "Duplicate detected"
    assert dups and dups[0][0].id == "q_similar"
    # Still in pending; not promoted
    assert storage.pending.get(q.id) is not None
    assert storage.chroma.get_question(q.id) is None


def test_get_question_pending_wins_over_chroma(storage: QuestionStorage):
    """If the same ID somehow exists in both, pending wins so the reviewer
    sees the in-flight version."""
    q_pending = _make_question(question="pending text")
    q_chroma = _make_question(question="chroma text")
    storage.pending.upsert(q_pending)
    storage.chroma.add_question(q_chroma)

    fetched = storage.get_question(q_pending.id)
    assert fetched.question == "pending text"


def test_update_question_routes_to_pending_when_pending(storage: QuestionStorage):
    q = _make_question(review_status="needs_revision")
    storage.pending.upsert(q)
    q.review_notes = "fixed wording"
    assert storage.update_question(q) is True
    assert storage.pending.get(q.id).review_notes == "fixed wording"


def test_update_question_routes_to_chroma_when_only_in_chroma(storage: QuestionStorage):
    q = _make_question(review_status="approved")
    storage.chroma.add_question(q)
    q.review_notes = "post-approval note"
    assert storage.update_question(q) is True
    assert storage.chroma.get_question(q.id).review_notes == "post-approval note"
    assert storage.pending.get(q.id) is None


def test_delete_falls_through_pending_then_chroma(storage: QuestionStorage):
    q_pending = _make_question(qid="q_pending")
    q_chroma = _make_question(qid="q_chroma")
    storage.pending.upsert(q_pending)
    storage.chroma.add_question(q_chroma)

    assert storage.delete_question("q_pending") is True
    assert storage.pending.get("q_pending") is None

    assert storage.delete_question("q_chroma") is True
    assert storage.chroma.get_question("q_chroma") is None


def test_search_pending_status_reads_from_pending_only(storage: QuestionStorage):
    storage.pending.upsert(_make_question(qid="p1", review_status="pending_review"))
    storage.pending.upsert(_make_question(qid="p2", review_status="pending_review"))
    # An approved question with an inconsistent status field should be ignored
    # by a pending-only search.
    storage.chroma.add_question(_make_question(qid="a1", review_status="approved"))

    results = storage.search_questions(filters={"review_status": "pending_review"}, limit=10)
    assert sorted(q.id for q in results) == ["p1", "p2"]


def test_search_unfiltered_unions_pending_and_chroma(storage: QuestionStorage):
    storage.pending.upsert(_make_question(qid="p1"))
    storage.chroma.add_question(_make_question(qid="a1", review_status="approved"))

    results = storage.search_questions(limit=10)
    ids = {q.id for q in results}
    assert ids == {"p1", "a1"}
