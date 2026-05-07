"""Storage service for questions with duplicate detection."""

from typing import List, Optional, Tuple
import uuid

import os

from quiz_shared.models.question import Question
from quiz_shared.database.chroma_client import ChromaDBClient
from quiz_shared.database.pending_store import PendingStore, SQLitePendingStore


_SIMPLE_FILTER_FIELDS = ("review_status", "difficulty", "topic", "category", "type", "source")


def _apply_simple_filters(questions: List[Question], filters: dict) -> List[Question]:
    """Apply scalar equality filters in-memory (PendingStore has no
    ChromaDB-style where clause, so we filter Python-side)."""
    if not filters:
        return questions
    out = questions
    for field in _SIMPLE_FILTER_FIELDS:
        if field in filters:
            expected = filters[field]
            out = [q for q in out if getattr(q, field, None) == expected]
    return out


class QuestionStorage:
    """Orchestrates the approved-question store (ChromaDB) and the pending
    review store. Approval moves a question from `PendingStore` into ChromaDB
    and removes it from `PendingStore`."""

    def __init__(
        self,
        chroma_client: Optional[ChromaDBClient] = None,
        pending_store: Optional[PendingStore] = None,
    ):
        """Initialize storage service.

        Args:
            chroma_client: ChromaDB client (or create default)
            pending_store: PendingStore for pre-approval questions (or create
                a default SQLite-backed one in `data/pending.db`)
        """
        if chroma_client is None:
            # Use absolute path to project root's chroma_data directory
            # This ensures all components use the same database
            project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../.."))
            chroma_path = os.path.join(project_root, "chroma_data")
            chroma_client = ChromaDBClient(persist_directory=chroma_path)

        self.chroma = chroma_client
        self.pending = pending_store if pending_store is not None else SQLitePendingStore()

    def check_duplicates(
        self,
        question: Question,
        threshold: float = 0.85
    ) -> List[Tuple[Question, float]]:
        """Check if question is duplicate using RAG semantic similarity.

        Args:
            question: Question to check
            threshold: Similarity threshold (default: 0.85)

        Returns:
            List of (similar_question, similarity_score) tuples

        Example:
            >>> storage = QuestionStorage()
            >>> duplicates = storage.check_duplicates(new_question)
            >>> if duplicates:
            ...     for dup, score in duplicates:
            ...         print(f"Similar ({score:.2f}): {dup.question}")
        """
        return self.chroma.find_duplicates(question.question, threshold)

    def add_pending(self, question: Question) -> bool:
        """Persist a freshly imported/generated question for review.

        The question stays in `PendingStore` until approved. ChromaDB is not
        touched — pending questions must not pollute semantic search.
        """
        if question.id.startswith("temp_"):
            question.id = f"q_{uuid.uuid4().hex[:12]}"
        if not question.review_status or question.review_status == "approved":
            question.review_status = "pending_review"
        return self.pending.upsert(question)

    def approve_question(
        self,
        question: Question,
        force: bool = False
    ) -> Tuple[bool, Optional[str], Optional[List[Tuple[Question, float]]]]:
        """Approve a question — write to ChromaDB, remove from PendingStore.

        Checks for duplicates unless force=True. If the question lives in the
        PendingStore (i.e. came from `/import` or generation), it is removed
        on success so the same row never lives in both stores.

        Args:
            question: Question to approve
            force: Skip duplicate check if True

        Returns:
            Tuple of (success, error_message, duplicates_found)
        """
        # Check for duplicates unless forced
        if not force:
            duplicates = self.check_duplicates(question)
            if duplicates:
                return False, "Duplicate detected", duplicates

        # Assign permanent ID if temp
        original_id = question.id
        if question.id.startswith("temp_"):
            question.id = f"q_{uuid.uuid4().hex[:12]}"

        question.review_status = "approved"

        # Store in ChromaDB
        success = self.chroma.add_question(question)

        if not success:
            return False, "Failed to store in database", None

        # Best-effort cleanup of the pending row (under either ID).
        for qid in {original_id, question.id}:
            self.pending.delete(qid)

        return True, None, None

    def bulk_approve(
        self,
        questions: List[Question],
        force: bool = False
    ) -> Tuple[List[Question], List[Tuple[Question, str]]]:
        """Approve multiple questions.

        Args:
            questions: List of questions to approve
            force: Skip duplicate checks

        Returns:
            Tuple of (approved_questions, failed_questions_with_reasons)
        """
        approved = []
        failed = []

        for question in questions:
            success, error, dups = self.approve_question(question, force)

            if success:
                approved.append(question)
            else:
                reason = error or "Unknown error"
                if dups:
                    reason = f"Duplicate of: {dups[0][0].question[:50]}..."
                failed.append((question, reason))

        return approved, failed

    def search_questions(
        self,
        query: Optional[str] = None,
        difficulty: Optional[str] = None,
        topic: Optional[str] = None,
        category: Optional[str] = None,
        filters: Optional[dict] = None,
        limit: int = 10
    ) -> List[Question]:
        """Search questions with filters.

        Pending review statuses (`pending_review`, `needs_revision`) are
        served from `PendingStore`; everything else from ChromaDB. Mixed or
        unfiltered queries union both sources so reviewer UIs that page
        through "all questions" still see everything.

        Args:
            query: Semantic search query (only honored against ChromaDB)
            difficulty: Filter by difficulty
            topic: Filter by topic
            category: Filter by category
            filters: Additional filters dict (e.g., {"review_status": "approved"})
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
        pending_statuses = {"pending_review", "needs_revision"}

        # Pending-only queries — answer from PendingStore alone.
        if status in pending_statuses and query is None:
            results = self.pending.list(status=status, limit=limit)
            return _apply_simple_filters(results, combined_filters)

        chroma_results = self.chroma.search_questions(
            query_text=query,
            filters=combined_filters,
            n_results=limit,
        )

        # Approved/rejected/explicit non-pending → ChromaDB only.
        if status is not None and status not in pending_statuses:
            return chroma_results

        # No status filter → union pending + chroma so reviewer UIs see both.
        pending_results = _apply_simple_filters(
            self.pending.list(limit=limit),
            combined_filters,
        )
        merged = pending_results + chroma_results
        return merged[:limit]

    def get_question(self, question_id: str) -> Optional[Question]:
        """Get question by ID.

        Pending store wins — a question being reviewed should be read from
        the same place the reviewer is editing it. Falls back to ChromaDB
        for already-approved questions.
        """
        pending = self.pending.get(question_id)
        if pending is not None:
            return pending
        return self.chroma.get_question(question_id)

    def delete_question(self, question_id: str) -> bool:
        """Delete a question from whichever store holds it."""
        if self.pending.delete(question_id):
            return True
        return self.chroma.delete_question(question_id)

    def update_question(self, question: Question) -> bool:
        """Update question in whichever store holds it.

        Reviewer edits to a pending question stay in the pending store.
        Edits to an approved question go to ChromaDB. If neither store has
        the row yet, the update lands in pending — covering the
        review-then-save flow on a freshly imported question.
        """
        if self.pending.get(question.id) is not None:
            return self.pending.upsert(question)
        if self.chroma.get_question(question.id) is not None:
            return self.chroma.update_question_obj(question)
        # Not yet persisted — treat as a new pending entry.
        return self.pending.upsert(question)

    def update_question_fields(
        self,
        question_id: str,
        updates: dict
    ) -> bool:
        """Update specific question fields.

        Args:
            question_id: Question ID
            updates: Dict of fields to update

        Returns:
            True if successful
        """
        return self.chroma.update_question(question_id, updates)

    def get_all_questions(self, limit: int = 1000) -> List[Question]:
        """Get all questions across pending + approved stores.

        Args:
            limit: Max results across the union (default: 1000)

        Returns:
            List of all questions
        """
        pending = self.pending.list(limit=limit)
        approved = self.chroma.get_all_questions(limit=limit)
        return (pending + approved)[:limit]

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
