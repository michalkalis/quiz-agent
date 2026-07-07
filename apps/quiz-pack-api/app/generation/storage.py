"""Storage service for pending-review questions.

ChromaDB is retired (#41, D4). Approved questions live in Postgres+pgvector,
written by the order pipeline's `PersistStage`. This service now fronts only
the `PendingStore` used by the legacy import/review tooling. The future
#42/#30 review flow must write approved questions to pgvector via
`PgvectorQuestionStore.upsert` — do NOT rebuild an approve path here.
"""

from typing import List, Optional
import uuid

from quiz_shared.models.question import Question
from quiz_shared.database.pending_store import PendingStore, SQLitePendingStore


_SIMPLE_FILTER_FIELDS = ("review_status", "difficulty", "topic", "category", "type", "source")


def _apply_simple_filters(questions: List[Question], filters: dict) -> List[Question]:
    """Apply scalar equality filters in-memory (PendingStore has no
    structured where clause, so we filter Python-side)."""
    if not filters:
        return questions
    out = questions
    for field in _SIMPLE_FILTER_FIELDS:
        if field in filters:
            expected = filters[field]
            out = [q for q in out if getattr(q, field, None) == expected]
    return out


class QuestionStorage:
    """Fronts the pre-approval `PendingStore` for the import/review tooling."""

    def __init__(self, pending_store: Optional[PendingStore] = None):
        """Initialize storage service.

        Args:
            pending_store: PendingStore for pre-approval questions (or create
                a default SQLite-backed one in `data/pending.db`)
        """
        self.pending = pending_store if pending_store is not None else SQLitePendingStore()

    def add_pending(self, question: Question) -> bool:
        """Persist a freshly imported/generated question for review.

        The question stays in `PendingStore` until the (future, pgvector-
        backed) review flow promotes it.
        """
        if question.id.startswith("temp_"):
            question.id = f"q_{uuid.uuid4().hex[:12]}"
        if not question.review_status or question.review_status == "approved":
            question.review_status = "pending_review"
        return self.pending.upsert(question)

    def search_questions(
        self,
        difficulty: Optional[str] = None,
        topic: Optional[str] = None,
        category: Optional[str] = None,
        filters: Optional[dict] = None,
        limit: int = 10
    ) -> List[Question]:
        """List pending-store questions matching scalar filters.

        Semantic search went away with ChromaDB (#41) — approved questions
        are queried in pgvector, not here.

        Args:
            difficulty: Filter by difficulty
            topic: Filter by topic
            category: Filter by category
            filters: Additional filters dict (e.g., {"review_status": "pending_review"})
            limit: Max results

        Returns:
            List of matching questions
        """
        combined_filters = filters.copy() if filters else {}

        if difficulty:
            combined_filters["difficulty"] = difficulty
        if topic:
            combined_filters["topic"] = topic
        if category:
            combined_filters["category"] = category

        status = combined_filters.get("review_status")
        results = self.pending.list(status=status, limit=limit)
        return _apply_simple_filters(results, combined_filters)

    def get_question(self, question_id: str) -> Optional[Question]:
        """Get a pending question by ID."""
        return self.pending.get(question_id)

    def delete_question(self, question_id: str) -> bool:
        """Delete a pending question."""
        return self.pending.delete(question_id)

    def update_question(self, question: Question) -> bool:
        """Upsert a question in the pending store (reviewer edits, status
        changes, and the review-then-save flow on a fresh import)."""
        return self.pending.upsert(question)

    def get_all_questions(self, limit: int = 1000) -> List[Question]:
        """Get all pending-store questions.

        Args:
            limit: Max results (default: 1000)

        Returns:
            List of all pending questions
        """
        return self.pending.list(limit=limit)

    def list_pending(
        self,
        status: Optional[str] = "pending_review",
        limit: int = 100,
        offset: int = 0,
    ) -> List[Question]:
        """List questions from `PendingStore` only."""
        return self.pending.list(status=status, limit=limit, offset=offset)

    def count_pending(self, status: Optional[str] = "pending_review") -> int:
        return self.pending.count(status=status)
