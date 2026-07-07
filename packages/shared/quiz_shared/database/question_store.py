"""QuestionStore — narrow seam over a vector store of Question records.

The production implementation is `PgvectorQuestionStore` (async; wrapped by
`SyncPgvectorStore` for sync callers).

`upsert` is the canonical write — it never silently no-ops on existing IDs.
Use it whenever you have a complete `Question` and want it persisted.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Protocol, Tuple

from ..models.question import Question


class QuestionStore(Protocol):
    """Narrow interface for question persistence and retrieval.

    Implementations are responsible for:
    - Serializing/deserializing `Question` to/from their backing store
    - Generating embeddings (or accepting them on the question)
    - Keeping `add` and `upsert` distinct: `add` errors on existing ID,
      `upsert` always writes
    """

    def add(self, question: Question) -> bool: ...
    def upsert(self, question: Question) -> bool: ...
    def get(self, question_id: str) -> Optional[Question]: ...
    def delete(self, question_id: str) -> bool: ...
    def search(
        self,
        query_text: Optional[str] = None,
        filters: Optional[Dict[str, Any]] = None,
        n_results: int = 10,
        excluded_ids: Optional[List[str]] = None,
    ) -> List[Question]: ...
    def count(self, filters: Optional[Dict[str, Any]] = None) -> int: ...
    def get_all(self, limit: int = 1000) -> List[Question]: ...
    def find_duplicates(
        self, question_text: str, threshold: float = 0.85
    ) -> List[Tuple[Question, float]]: ...
