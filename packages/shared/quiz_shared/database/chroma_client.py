"""Legacy facade over `ChromaDBQuestionStore`.

Existing scripts and the question-generator app import `ChromaDBClient`
directly. New code should depend on `QuestionStore` (see `question_store.py`)
instead — this class is kept only so those legacy callers keep working.

All metadata serialization lives in `ChromaDBQuestionStore`; this class
delegates to it.
"""

import logging
from typing import Any, Dict, List, Optional, Tuple

import chromadb

from ..models.question import Question
from .question_store import ChromaDBQuestionStore

logger = logging.getLogger(__name__)


class ChromaDBClient:
    """Thin facade over `ChromaDBQuestionStore` for legacy callers.

    Preserves the old method names (`add_question`, `update_question_obj`,
    etc.) so scripts and apps that still import this class keep working
    while the canonical seam is `QuestionStore`.
    """

    def __init__(
        self,
        persist_directory: str = "./chroma_data",
        collection_name: str = "quiz_questions",
    ):
        self.client = chromadb.PersistentClient(path=persist_directory)
        self.collection_name = collection_name
        self.collection = self._get_or_create_collection()
        self._store = ChromaDBQuestionStore(self.collection)

    def _get_or_create_collection(self):
        try:
            return self.client.get_collection(self.collection_name)
        except Exception:
            return self.client.create_collection(
                name=self.collection_name,
                metadata={
                    "description": "Pub quiz questions with embeddings",
                    "hnsw:space": "cosine",
                },
            )

    @property
    def store(self) -> ChromaDBQuestionStore:
        """Expose the underlying store for callers being migrated to the new seam."""
        return self._store

    # ── Writes ──────────────────────────────────────────────────────────────

    def add_question(self, question: Question) -> bool:
        return self._store.add(question)

    def update_question_obj(self, question: Question) -> bool:
        """Add-or-replace a question. Equivalent to `store.upsert`."""
        return self._store.upsert(question)

    def update_question(self, question_id: str, updates: Dict[str, Any]) -> bool:
        """Apply partial updates to a question. Uses upsert under the hood.

        Historical note: this method used to silently no-op on existing IDs
        because it called `add_question` which mapped to `collection.add`.
        It now goes through `store.upsert` and behaves correctly.
        """
        try:
            question = self._store.get(question_id)
            if not question:
                return False
            for key, value in updates.items():
                if hasattr(question, key):
                    setattr(question, key, value)
            return self._store.upsert(question)
        except Exception as e:
            logger.error("Error updating question: %s", e)
            return False

    def update_rating(self, question_id: str, user_id: str, rating: int) -> bool:
        try:
            question = self._store.get(question_id)
            if not question:
                return False
            question.user_ratings[user_id] = rating
            question.usage_count += 1
            return self._store.upsert(question)
        except Exception as e:
            logger.error("Error updating rating: %s", e)
            return False

    def delete_question(self, question_id: str) -> bool:
        return self._store.delete(question_id)

    # ── Reads ───────────────────────────────────────────────────────────────

    def get_question(self, question_id: str) -> Optional[Question]:
        return self._store.get(question_id)

    def count_questions(self, filters: Optional[Dict[str, Any]] = None) -> int:
        return self._store.count(filters)

    def get_all_questions(self, limit: int = 1000) -> List[Question]:
        return self._store.get_all(limit=limit)

    def search_questions(
        self,
        query_text: Optional[str] = None,
        filters: Optional[Dict[str, Any]] = None,
        n_results: int = 10,
        excluded_ids: Optional[List[str]] = None,
    ) -> List[Question]:
        return self._store.search(
            query_text=query_text,
            filters=filters,
            n_results=n_results,
            excluded_ids=excluded_ids,
        )

    def find_duplicates(
        self, question_text: str, threshold: float = 0.85
    ) -> List[Tuple[Question, float]]:
        return self._store.find_duplicates(question_text, threshold=threshold)
