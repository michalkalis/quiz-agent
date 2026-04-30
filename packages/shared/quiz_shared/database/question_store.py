"""QuestionStore — narrow seam over a vector store of Question records.

The store owns metadata serialization in one place. Two callers (`add` and
`upsert`) share a single `_question_to_metadata` helper, eliminating the
80-line duplication that used to live in `ChromaDBClient.add_question` and
`update_question_obj`.

`upsert` is the canonical write — it never silently no-ops on existing IDs.
Use it whenever you have a complete `Question` and want it persisted.
"""

from __future__ import annotations

import json
import logging
from datetime import datetime
from typing import Any, Callable, Dict, List, Optional, Protocol, Tuple

from ..models.question import Question
from ..utils.embeddings import generate_embedding

logger = logging.getLogger(__name__)


Embedder = Callable[[str], List[float]]


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


class ChromaDBQuestionStore:
    """ChromaDB-backed `QuestionStore`.

    Constructed from a `chromadb` collection plus an embedder callable.
    The collection is private — callers go through the store interface.
    """

    def __init__(self, collection: Any, embedder: Embedder = generate_embedding):
        self._collection = collection
        self._embedder = embedder

    # ── Writes ──────────────────────────────────────────────────────────────

    def add(self, question: Question) -> bool:
        """Add a new question. Errors if ID already exists.

        Use `upsert` if you want add-or-replace semantics.
        """
        try:
            embedding = self._embedding_for(question)
            metadata = self._question_to_metadata(question)
            self._collection.add(
                ids=[question.id],
                documents=[question.question],
                metadatas=[metadata],
                embeddings=[embedding],
            )
            return True
        except Exception as e:
            logger.error("Error adding question: %s", e)
            return False

    def upsert(self, question: Question) -> bool:
        """Add or replace a question. Canonical write — never silently no-ops."""
        try:
            embedding = self._embedding_for(question)
            metadata = self._question_to_metadata(question)
            self._collection.upsert(
                ids=[question.id],
                documents=[question.question],
                metadatas=[metadata],
                embeddings=[embedding],
            )
            return True
        except Exception as e:
            logger.error("Error upserting question: %s", e, exc_info=True)
            return False

    def delete(self, question_id: str) -> bool:
        try:
            self._collection.delete(ids=[question_id])
            return True
        except Exception as e:
            logger.error("Error deleting question: %s", e)
            return False

    # ── Reads ───────────────────────────────────────────────────────────────

    def get(self, question_id: str) -> Optional[Question]:
        try:
            result = self._collection.get(
                ids=[question_id],
                include=["embeddings", "documents", "metadatas"],
            )
            if not result["ids"]:
                return None

            embedding = None
            embeddings = result.get("embeddings")
            if embeddings is not None and len(embeddings) > 0 and embeddings[0] is not None:
                embedding = embeddings[0]

            return self._metadata_to_question(
                question_id,
                result["documents"][0],
                result["metadatas"][0],
                embedding=embedding,
            )
        except Exception as e:
            logger.error("Error getting question: %s", e, exc_info=True)
            return None

    def count(self, filters: Optional[Dict[str, Any]] = None) -> int:
        try:
            where_clause = self._build_where_clause(filters or {})
            results = (
                self._collection.get(where=where_clause)
                if where_clause
                else self._collection.get()
            )
            ids = results.get("ids") or []
            return len(ids)
        except Exception as e:
            logger.error("Error counting questions: %s", e)
            return 0

    def get_all(self, limit: int = 1000) -> List[Question]:
        try:
            results = self._collection.get(limit=limit)
            return self._results_to_questions(results, flat=True)
        except Exception as e:
            logger.error("Error getting all questions: %s", e)
            return []

    def search(
        self,
        query_text: Optional[str] = None,
        filters: Optional[Dict[str, Any]] = None,
        n_results: int = 10,
        excluded_ids: Optional[List[str]] = None,
    ) -> List[Question]:
        try:
            where_clause = self._build_where_clause(filters or {})

            # Fetch extra to compensate for client-side excluded-ID filtering
            fetch_count = n_results
            if excluded_ids:
                fetch_count = n_results + len(excluded_ids)

            if query_text:
                query_embedding = self._embedder(query_text)
                results = self._collection.query(
                    query_embeddings=[query_embedding],
                    where=where_clause if where_clause else None,
                    n_results=fetch_count,
                    include=["embeddings", "documents", "metadatas"],
                )
                flat = False
            else:
                results = self._collection.get(
                    where=where_clause if where_clause else None,
                    limit=fetch_count,
                    include=["embeddings", "documents", "metadatas"],
                )
                flat = True

            questions = self._results_to_questions(results, flat=flat)
            if excluded_ids:
                excluded = set(excluded_ids)
                questions = [q for q in questions if q.id not in excluded]
            return questions
        except Exception as e:
            logger.error("Error searching questions: %s", e, exc_info=True)
            return []

    def find_duplicates(
        self, question_text: str, threshold: float = 0.85
    ) -> List[Tuple[Question, float]]:
        try:
            query_embedding = self._embedder(question_text)
            results = self._collection.query(
                query_embeddings=[query_embedding],
                n_results=10,
            )

            duplicates: List[Tuple[Question, float]] = []
            ids = results.get("ids") or []
            if not ids or not ids[0]:
                return duplicates

            ids_inner = ids[0]
            documents = results["documents"][0]
            metadatas = results["metadatas"][0]
            distances = results.get("distances", [[]])[0] if results.get("distances") else []

            for i, qid in enumerate(ids_inner):
                similarity = 1 - distances[i] if distances else 0.0
                if similarity >= threshold:
                    duplicates.append(
                        (
                            self._metadata_to_question(qid, documents[i], metadatas[i]),
                            similarity,
                        )
                    )
            return duplicates
        except Exception as e:
            logger.error("Error finding duplicates: %s", e)
            return []

    # ── Internal helpers ────────────────────────────────────────────────────

    def _embedding_for(self, question: Question) -> List[float]:
        """Reuse cached embedding if the question carries one; else generate."""
        if question.embedding is not None:
            return question.embedding
        return self._embedder(question.question)

    @staticmethod
    def _question_to_metadata(question: Question) -> Dict[str, Any]:
        """Serialize a Question to ChromaDB metadata. Single source of truth.

        Used by both `add` and `upsert` so a field-level change lands in one
        place. ChromaDB metadata is flat key/value, so list/dict fields are
        JSON-encoded.
        """
        metadata: Dict[str, Any] = {
            "type": question.type,
            "correct_answer": (
                question.correct_answer
                if isinstance(question.correct_answer, str)
                else json.dumps(question.correct_answer)
            ),
            "topic": question.topic,
            "category": question.category,
            "difficulty": question.difficulty,
            "tags": json.dumps(question.tags),
            "created_at": question.created_at.isoformat(),
            "source": question.source,
            "usage_count": question.usage_count,
            "user_ratings": json.dumps(question.user_ratings),
            "review_status": question.review_status,
            "language_dependent": question.language_dependent,
        }

        if question.possible_answers:
            metadata["possible_answers"] = json.dumps(question.possible_answers)
        if question.alternative_answers:
            metadata["alternative_answers"] = json.dumps(question.alternative_answers)
        if question.created_by:
            metadata["created_by"] = question.created_by
        if question.media_url:
            metadata["media_url"] = question.media_url
        if question.image_subtype:
            metadata["image_subtype"] = question.image_subtype
        if question.media_duration_seconds:
            metadata["media_duration_seconds"] = question.media_duration_seconds
        if question.explanation:
            metadata["explanation"] = question.explanation
        if question.source_url:
            metadata["source_url"] = question.source_url
        if question.source_excerpt:
            metadata["source_excerpt"] = question.source_excerpt

        if question.reviewed_by:
            metadata["reviewed_by"] = question.reviewed_by
        if question.reviewed_at:
            metadata["reviewed_at"] = question.reviewed_at.isoformat()
        if question.review_notes:
            metadata["review_notes"] = question.review_notes
        if question.quality_ratings:
            metadata["quality_ratings"] = json.dumps(question.quality_ratings)
        if question.generation_metadata:
            metadata["generation_metadata"] = json.dumps(question.generation_metadata)

        if question.expires_at:
            metadata["expires_at"] = question.expires_at.isoformat()
        if question.freshness_tag:
            metadata["freshness_tag"] = question.freshness_tag

        return metadata

    @staticmethod
    def _metadata_to_question(
        question_id: str,
        question_text: str,
        metadata: Dict[str, Any],
        embedding: Optional[List[float]] = None,
    ) -> Question:
        tags = json.loads(metadata.get("tags", "[]"))
        user_ratings = json.loads(metadata.get("user_ratings", "{}"))

        correct_answer_raw = metadata.get("correct_answer", "")
        try:
            correct_answer = json.loads(correct_answer_raw)
        except (json.JSONDecodeError, TypeError):
            correct_answer = correct_answer_raw
        if not isinstance(correct_answer, (str, list)):
            correct_answer = str(correct_answer)

        possible_answers = (
            json.loads(metadata["possible_answers"])
            if "possible_answers" in metadata
            else None
        )
        alternative_answers = (
            json.loads(metadata["alternative_answers"])
            if "alternative_answers" in metadata
            else []
        )
        quality_ratings = (
            json.loads(metadata["quality_ratings"])
            if "quality_ratings" in metadata
            else None
        )
        generation_metadata = (
            json.loads(metadata["generation_metadata"])
            if "generation_metadata" in metadata
            else None
        )
        reviewed_at = (
            datetime.fromisoformat(metadata["reviewed_at"])
            if "reviewed_at" in metadata
            else None
        )
        expires_at = (
            datetime.fromisoformat(metadata["expires_at"])
            if "expires_at" in metadata
            else None
        )

        return Question(
            id=question_id,
            question=question_text,
            type=metadata.get("type", "text"),
            possible_answers=possible_answers,
            correct_answer=correct_answer,
            alternative_answers=alternative_answers,
            topic=metadata.get("topic", "General"),
            category=metadata.get("category", "general"),
            difficulty=metadata.get("difficulty", "medium"),
            tags=tags,
            language_dependent=metadata.get("language_dependent", False),
            created_at=datetime.fromisoformat(
                metadata.get("created_at", datetime.now().isoformat())
            ),
            created_by=metadata.get("created_by"),
            source=metadata.get("source", "generated"),
            usage_count=metadata.get("usage_count", 0),
            user_ratings=user_ratings,
            media_url=metadata.get("media_url"),
            image_subtype=metadata.get("image_subtype"),
            media_duration_seconds=metadata.get("media_duration_seconds"),
            explanation=metadata.get("explanation"),
            source_url=metadata.get("source_url"),
            source_excerpt=metadata.get("source_excerpt"),
            review_status=metadata.get("review_status", "pending_review"),
            reviewed_by=metadata.get("reviewed_by"),
            reviewed_at=reviewed_at,
            review_notes=metadata.get("review_notes"),
            quality_ratings=quality_ratings,
            generation_metadata=generation_metadata,
            embedding=embedding,
            expires_at=expires_at,
            freshness_tag=metadata.get("freshness_tag"),
        )

    @staticmethod
    def _build_where_clause(filters: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Translate a flat filter dict to ChromaDB's where syntax.

        ChromaDB requires multiple top-level conditions to be wrapped in `$and`.
        Operator keys (starting with `$`) pass through.
        """
        top_level: Dict[str, Any] = {}
        operators: Dict[str, Any] = {}
        for key, value in filters.items():
            if key.startswith("$"):
                operators[key] = value
            else:
                top_level[key] = value

        if len(top_level) > 1:
            where: Dict[str, Any] = {"$and": [{k: v} for k, v in top_level.items()]}
            where.update(operators)
            return where
        if len(top_level) == 1:
            where = dict(top_level)
            where.update(operators)
            return where
        return operators or None

    def _results_to_questions(
        self, results: Dict[str, Any], flat: bool
    ) -> List[Question]:
        """Convert a ChromaDB query/get result into a list of Question.

        - `flat=True` for `collection.get()` shape: ids, documents, metadatas, embeddings as flat lists
        - `flat=False` for `collection.query()` shape: same fields wrapped in an outer list
        """
        ids_field = results.get("ids") or []
        if not ids_field or (not flat and not ids_field[0]):
            return []

        if flat:
            ids = ids_field
            documents = results.get("documents") or []
            metadatas = results.get("metadatas") or []
            embeddings = results.get("embeddings")
        else:
            ids = ids_field[0]
            documents = (results.get("documents") or [[]])[0]
            metadatas = (results.get("metadatas") or [[]])[0]
            embeddings_outer = results.get("embeddings")
            embeddings = embeddings_outer[0] if embeddings_outer else None

        if embeddings is None:
            embeddings = [None] * len(ids)

        return [
            self._metadata_to_question(
                qid,
                documents[i],
                metadatas[i],
                embedding=embeddings[i] if i < len(embeddings) else None,
            )
            for i, qid in enumerate(ids)
        ]
