"""Tests for PendingStore — both InMemory and SQLite adapters.

Both adapters must satisfy the same contract; the parametrized fixture lets
us prove that without duplicating tests.
"""

from __future__ import annotations

import pytest

from quiz_shared.database.pending_store import (
    InMemoryPendingStore,
    PendingStore,
    SQLitePendingStore,
)
from quiz_shared.models.question import Question


def _make_question(qid: str = "q_test_001", **overrides) -> Question:
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


@pytest.fixture(params=["memory", "sqlite"])
def store(request, tmp_path) -> PendingStore:
    if request.param == "memory":
        return InMemoryPendingStore()
    db_path = tmp_path / "pending.db"
    return SQLitePendingStore(database_url=f"sqlite:///{db_path}")


def test_add_and_get_roundtrip(store: PendingStore):
    q = _make_question()
    assert store.add(q) is True
    fetched = store.get(q.id)
    assert fetched is not None
    assert fetched.id == q.id
    assert fetched.question == q.question
    assert fetched.review_status == "pending_review"


def test_add_duplicate_id_fails(store: PendingStore):
    q = _make_question()
    assert store.add(q) is True
    assert store.add(q) is False  # second add must error


def test_upsert_inserts_new(store: PendingStore):
    q = _make_question()
    assert store.upsert(q) is True
    assert store.get(q.id) is not None


def test_upsert_replaces_existing(store: PendingStore):
    q = _make_question(question="Original")
    store.add(q)
    q2 = _make_question(question="Edited", review_status="needs_revision")
    assert store.upsert(q2) is True
    fetched = store.get(q.id)
    assert fetched.question == "Edited"
    assert fetched.review_status == "needs_revision"


def test_delete_removes_row(store: PendingStore):
    q = _make_question()
    store.add(q)
    assert store.delete(q.id) is True
    assert store.get(q.id) is None
    assert store.delete(q.id) is False  # second delete is a no-op


def test_get_missing_returns_none(store: PendingStore):
    assert store.get("never_existed") is None


def test_list_filters_by_status(store: PendingStore):
    pending = _make_question(qid="q_pending", review_status="pending_review")
    revision = _make_question(qid="q_revision", review_status="needs_revision")
    store.add(pending)
    store.add(revision)

    pending_only = store.list(status="pending_review")
    assert [q.id for q in pending_only] == ["q_pending"]

    revision_only = store.list(status="needs_revision")
    assert [q.id for q in revision_only] == ["q_revision"]

    everything = store.list()
    assert {q.id for q in everything} == {"q_pending", "q_revision"}


def test_list_pagination(store: PendingStore):
    for i in range(5):
        store.add(_make_question(qid=f"q_{i:03d}"))

    page = store.list(limit=2, offset=1)
    assert len(page) == 2


def test_count_total_and_by_status(store: PendingStore):
    store.add(_make_question(qid="a", review_status="pending_review"))
    store.add(_make_question(qid="b", review_status="pending_review"))
    store.add(_make_question(qid="c", review_status="needs_revision"))

    assert store.count() == 3
    assert store.count(status="pending_review") == 2
    assert store.count(status="needs_revision") == 1
    assert store.count(status="nonexistent") == 0


def test_in_memory_returns_copies(store: PendingStore):
    """Mutating a returned Question must not corrupt the store."""
    q = _make_question(question="original")
    store.add(q)
    fetched = store.get(q.id)
    fetched.question = "mutated locally"
    assert store.get(q.id).question == "original"


def test_sqlite_roundtrip_preserves_quality_ratings(tmp_path):
    """Regression: review payload (quality_ratings, review_notes) must survive
    a JSON roundtrip through SQLite."""
    db_path = tmp_path / "pending.db"
    store = SQLitePendingStore(database_url=f"sqlite:///{db_path}")
    q = _make_question(
        review_notes="great question",
        quality_ratings={"surprise_factor": 4, "clarity": 5,
                         "universal_appeal": 4, "creativity": 5},
    )
    store.upsert(q)
    fetched = store.get(q.id)
    assert fetched.review_notes == "great question"
    assert fetched.quality_ratings == {
        "surprise_factor": 4,
        "clarity": 5,
        "universal_appeal": 4,
        "creativity": 5,
    }
