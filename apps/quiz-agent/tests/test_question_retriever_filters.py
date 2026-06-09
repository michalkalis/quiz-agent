"""Tests for QuestionRetriever type-filter single-source-of-truth (issue #50, task 50.1).

ALLOWED_QUESTION_TYPES is the sole source of truth for which question types reach the
voice-quiz retriever.  These tests monkeypatch that constant and prove that *every*
filter path — primary and all three fallbacks — picks it up.  A stale literal in any
fallback would silently drop MCQ questions on unhappy paths only; this suite catches that.
"""

from unittest.mock import patch

from quiz_shared.models.session import QuizSession

import app.retrieval.question_retriever as retriever_module
from app.retrieval.question_retriever import QuestionRetriever


# ---------------------------------------------------------------------------
# Stub store — records all `filters` args, always returns [] so the full
# fallback chain (FB-1 → FB-2 × 3 difficulties → FB-3) always runs.
# ---------------------------------------------------------------------------


class _StubStore:
    def __init__(self):
        self.calls: list[dict] = []

    def search(self, *, query_text, filters, n_results, excluded_ids=None):
        self.calls.append(dict(filters))
        return []


def _make_session(difficulty="easy") -> QuizSession:
    return QuizSession(session_id="test-sess")


# ---------------------------------------------------------------------------
# Part (a): _build_metadata_filters reflects patched constant
# ---------------------------------------------------------------------------


def test_build_metadata_filters_uses_constant():
    """_build_metadata_filters type filter must come from ALLOWED_QUESTION_TYPES."""
    stub = _StubStore()
    retriever = QuestionRetriever(question_store=stub)
    session = _make_session()

    with patch.object(retriever_module, "ALLOWED_QUESTION_TYPES", ["patched_type"]):
        filters = retriever._build_metadata_filters("easy", session)

    assert filters["type"]["$in"] == ["patched_type"]


# ---------------------------------------------------------------------------
# Part (b): all three fallback store.search calls pass the patched constant
# ---------------------------------------------------------------------------


def test_fallback_chain_all_paths_use_constant():
    """All three fallback store.search calls must pass the patched ALLOWED_QUESTION_TYPES."""
    stub = _StubStore()
    retriever = QuestionRetriever(question_store=stub)
    session = _make_session()

    with patch.object(retriever_module, "ALLOWED_QUESTION_TYPES", ["sentinel_type"]):
        retriever._fallback_retrieval(
            session=session,
            question_difficulty="easy",
            n_candidates=5,
            excluded_ids=[],
        )

    assert len(stub.calls) >= 3, "Expected at least FB-1, FB-2×2, FB-3 calls"

    for i, call_filters in enumerate(stub.calls):
        assert call_filters["type"]["$in"] == ["sentinel_type"], (
            f"call {i} passed {call_filters['type']['$in']!r} instead of ['sentinel_type']"
        )
