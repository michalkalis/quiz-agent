"""Storage service for questions with duplicate detection."""

from typing import List, Optional, Tuple
import uuid

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared"))

from quiz_shared.models.question import Question
from quiz_shared.database.chroma_client import ChromaDBClient


class QuestionStorage:
    """Manages question storage with RAG-based duplicate detection."""

    def __init__(self, chroma_client: Optional[ChromaDBClient] = None):
        """Initialize storage service.

        Args:
            chroma_client: ChromaDB client (or create default)
        """
        self.chroma = chroma_client or ChromaDBClient()

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

    def approve_question(
        self,
        question: Question,
        force: bool = False
    ) -> Tuple[bool, Optional[str], Optional[List[Tuple[Question, float]]]]:
        """Approve and store a question.

        Checks for duplicates unless force=True.

        Args:
            question: Question to approve
            force: Skip duplicate check if True

        Returns:
            Tuple of (success, error_message, duplicates_found)

        Example:
            >>> success, error, dups = storage.approve_question(question)
            >>> if not success:
            ...     if dups:
            ...         print(f"Found {len(dups)} similar questions")
            ...     else:
            ...         print(f"Error: {error}")
        """
        # Check for duplicates unless forced
        if not force:
            duplicates = self.check_duplicates(question)
            if duplicates:
                return False, "Duplicate detected", duplicates

        # Assign permanent ID if temp
        if question.id.startswith("temp_"):
            question.id = f"q_{uuid.uuid4().hex[:12]}"

        # Store in ChromaDB
        success = self.chroma.add_question(question)

        if success:
            return True, None, None
        else:
            return False, "Failed to store in database", None

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

        Args:
            query: Semantic search query
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

        return self.chroma.search_questions(
            query_text=query,
            filters=combined_filters,
            n_results=limit
        )

    def get_question(self, question_id: str) -> Optional[Question]:
        """Get question by ID.

        Args:
            question_id: Question ID

        Returns:
            Question object or None
        """
        return self.chroma.get_question(question_id)

    def delete_question(self, question_id: str) -> bool:
        """Delete a question.

        Args:
            question_id: Question ID

        Returns:
            True if successful
        """
        return self.chroma.delete_question(question_id)

    def update_question(self, question: Question) -> bool:
        """Update question in database.

        Args:
            question: Question object with updates

        Returns:
            True if successful
        """
        return self.chroma.update_question_obj(question)

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
        """Get all questions from database.

        Args:
            limit: Max results (default: 1000)

        Returns:
            List of all questions
        """
        return self.chroma.get_all_questions(limit=limit)
