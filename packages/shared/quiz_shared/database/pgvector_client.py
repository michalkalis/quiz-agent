"""Pgvector-backed `QuestionStore` (issue #36 task 2.19).

Async client over the ``questions`` table that quiz-pack-api manages via
alembic. The voice-quiz read path (task 2.20) is the primary consumer:
``apps/quiz-agent/app/retrieval/question_retriever.py`` swaps its
``ChromaDBClient`` default for this store.

Design notes
------------
- **Async-only.** Pgvector queries go through SQLAlchemy + asyncpg.
  ``QuestionRetriever`` is sync; task 2.20 adapts at that seam, accepting
  the minor blocking cost in the voice-quiz hot path.
- **Schema duplication is deliberate.** The ORM model lives in
  ``apps/quiz-pack-api/app/db/models/question.py``. Re-importing it here
  would invert the dependency direction (shared → app). Instead this file
  declares a *minimal* SQLAlchemy Core ``Table`` that mirrors only the
  columns the read path touches. The authoritative schema is alembic's.
- Cosine similarity uses pgvector's ``<=>`` operator (``cosine_distance``).
  Lower distance = more similar; results are returned ordered ascending.
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone
from typing import Any, Callable, Dict, List, Optional

from pgvector.sqlalchemy import Vector
from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    Integer,
    MetaData,
    String,
    Table,
    Text,
    func,
    select,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from ..models.question import GenerationProvenance, Question
from ..utils.embeddings import generate_embedding

logger = logging.getLogger(__name__)

EMBEDDING_DIM = 1536

Embedder = Callable[[str], List[float]]

# Minimal mirror of the `questions` table managed by quiz-pack-api alembic.
# Only the columns the voice-quiz read path needs are declared; INSERTs
# rely on Postgres defaults / nullable columns for everything else.
_metadata = MetaData()
questions_table = Table(
    "questions",
    _metadata,
    Column("id", PGUUID(as_uuid=True), primary_key=True),
    Column("question", Text, nullable=False),
    Column("type", String(32), nullable=False),
    Column("possible_answers", JSONB, nullable=True),
    Column("correct_answer", JSONB, nullable=False),
    Column("alternative_answers", JSONB, nullable=False),
    Column("topic", String(128), nullable=False),
    Column("category", String(64), nullable=False),
    Column("difficulty", String(16), nullable=False),
    Column("tags", JSONB, nullable=False),
    Column("language_dependent", Boolean, nullable=False),
    Column("age_appropriate", String(8), nullable=True),
    Column("language", String(16), nullable=True),
    Column("pack_id", PGUUID(as_uuid=True), nullable=True),
    Column("source", String(32), nullable=False),
    Column("source_url", Text, nullable=True),
    Column("source_excerpt", Text, nullable=True),
    Column("review_status", String(32), nullable=False),
    Column("embedding", Vector(EMBEDDING_DIM), nullable=True),
    Column("embedding_model", String(64), nullable=True),
    Column("embedding_dim", Integer, nullable=True),
    Column("usage_count", Integer, nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False),
    Column("expires_at", DateTime(timezone=True), nullable=True),
    Column("freshness_tag", String(64), nullable=True),
    Column("explanation", Text, nullable=True),
    Column("media_url", Text, nullable=True),
    Column("image_subtype", String(32), nullable=True),
    Column("provenance", JSONB, nullable=True),
)


# Filter operators allowed via the QuestionStore.search filters dict.
# ChromaDB-style ``{"$in": [...]}`` keeps `QuestionRetriever` filter
# construction working unchanged at the seam.
def _build_where(filters: Dict[str, Any]) -> List[Any]:
    """Translate ChromaDB-style filter dict to SQLAlchemy WHERE clauses."""
    clauses: List[Any] = []
    for key, value in filters.items():
        col = questions_table.c.get(key)
        if col is None:
            # Unknown filter key — skip silently so callers can pass
            # over-specified dicts. The store contract is "best-effort
            # constraint", not strict validation.
            continue
        if isinstance(value, dict) and "$in" in value:
            clauses.append(col.in_(value["$in"]))
        elif isinstance(value, dict) and "$ne" in value:
            clauses.append(col != value["$ne"])
        else:
            clauses.append(col == value)
    return clauses


class PgvectorQuestionStore:
    """Async pgvector-backed implementation of the `QuestionStore` shape."""

    def __init__(
        self,
        session_factory: Optional[async_sessionmaker[AsyncSession]] = None,
        database_url: Optional[str] = None,
        embedder: Embedder = generate_embedding,
    ) -> None:
        if session_factory is None:
            if not database_url:
                raise ValueError(
                    "PgvectorQuestionStore requires session_factory or database_url"
                )
            engine = create_async_engine(database_url)
            session_factory = async_sessionmaker(
                engine, class_=AsyncSession, expire_on_commit=False
            )
        self._session_factory = session_factory
        self._embedder = embedder

    # ── Writes ─────────────────────────────────────────────────────────

    async def add(self, question: Question) -> bool:
        """Insert a question. Idempotent on id via `ON CONFLICT DO NOTHING`."""
        embedding = self._embedding_for(question)
        row = _question_to_row_dict(question, embedding)
        try:
            async with self._session_factory() as session:
                stmt = (
                    pg_insert(questions_table)
                    .values(row)
                    .on_conflict_do_nothing(index_elements=["id"])
                )
                await session.execute(stmt)
                await session.commit()
            return True
        except Exception as e:  # pragma: no cover - surface only on DB outage
            logger.error("PgvectorQuestionStore.add failed: %s", e, exc_info=True)
            return False

    # ── Reads ──────────────────────────────────────────────────────────

    async def get(self, question_id: str) -> Optional[Question]:
        qid = _coerce_uuid(question_id)
        if qid is None:
            return None
        async with self._session_factory() as session:
            result = await session.execute(
                select(questions_table).where(questions_table.c.id == qid)
            )
            row = result.mappings().first()
            return _row_to_question(row) if row else None

    async def count(self, filters: Optional[Dict[str, Any]] = None) -> int:
        stmt = select(func.count()).select_from(questions_table)
        for clause in _build_where(filters or {}):
            stmt = stmt.where(clause)
        async with self._session_factory() as session:
            result = await session.execute(stmt)
            return int(result.scalar_one())

    async def search(
        self,
        query_text: Optional[str] = None,
        filters: Optional[Dict[str, Any]] = None,
        n_results: int = 10,
        excluded_ids: Optional[List[str]] = None,
    ) -> List[Question]:
        """Semantic search via pgvector cosine distance (`<=>`).

        Falls back to a plain SELECT (no ordering) when ``query_text`` is
        None, mirroring the ChromaDB store's behaviour.
        """
        fetch_count = n_results + (len(excluded_ids) if excluded_ids else 0)
        stmt = select(questions_table)
        for clause in _build_where(filters or {}):
            stmt = stmt.where(clause)

        if excluded_ids:
            excluded_uuids = [_coerce_uuid(x) for x in excluded_ids]
            excluded_uuids = [u for u in excluded_uuids if u is not None]
            if excluded_uuids:
                stmt = stmt.where(~questions_table.c.id.in_(excluded_uuids))

        if query_text:
            query_embedding = self._embedder(query_text)
            stmt = stmt.where(questions_table.c.embedding.is_not(None)).order_by(
                questions_table.c.embedding.cosine_distance(query_embedding)
            )

        stmt = stmt.limit(fetch_count)
        async with self._session_factory() as session:
            result = await session.execute(stmt)
            return [_row_to_question(row) for row in result.mappings().all()][
                :n_results
            ]

    # ── Internal helpers ───────────────────────────────────────────────

    def _embedding_for(self, question: Question) -> Optional[List[float]]:
        if question.embedding is not None:
            return list(question.embedding)
        if not question.question:
            return None
        return self._embedder(question.question)


# ── Row ↔ Question seam ────────────────────────────────────────────────


def _coerce_uuid(value: Optional[str]) -> Optional[uuid.UUID]:
    if value is None:
        return None
    try:
        return uuid.UUID(value)
    except (ValueError, AttributeError, TypeError):
        return None


def _question_to_row_dict(
    q: Question, embedding: Optional[List[float]]
) -> Dict[str, Any]:
    qid = _coerce_uuid(q.id) or uuid.uuid4()
    return {
        "id": qid,
        "question": q.question,
        "type": q.type,
        "possible_answers": q.possible_answers,
        "correct_answer": q.correct_answer,
        "alternative_answers": list(q.alternative_answers),
        "topic": q.topic,
        "category": q.category,
        "difficulty": q.difficulty,
        "tags": list(q.tags),
        "language_dependent": q.language_dependent,
        "age_appropriate": q.age_appropriate,
        "language": q.language,
        "pack_id": _coerce_uuid(q.pack_id),
        "source": q.source,
        "source_url": q.source_url,
        "source_excerpt": q.source_excerpt,
        "review_status": q.review_status,
        "embedding": embedding,
        "embedding_model": q.embedding_model or ("text-embedding-3-small" if embedding else None),
        "embedding_dim": q.embedding_dim or (len(embedding) if embedding else None),
        "usage_count": q.usage_count,
        "created_at": _ensure_utc(q.created_at) or datetime.now(timezone.utc),
        "expires_at": _ensure_utc(q.expires_at),
        "freshness_tag": q.freshness_tag,
        "explanation": q.explanation,
        "media_url": q.media_url,
        "image_subtype": q.image_subtype,
        "provenance": (
            q.generation_metadata.model_dump(mode="json")
            if q.generation_metadata is not None
            else None
        ),
    }


def _ensure_utc(dt: Optional[datetime]) -> Optional[datetime]:
    if dt is None:
        return None
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def _row_to_question(row: Any) -> Question:
    embedding = row["embedding"]
    if embedding is not None:
        embedding = [float(x) for x in embedding]

    provenance = row.get("provenance") if hasattr(row, "get") else row["provenance"]
    generation_metadata = (
        GenerationProvenance.model_validate(provenance) if provenance else None
    )

    return Question(
        id=str(row["id"]),
        question=row["question"],
        type=row["type"],
        possible_answers=row["possible_answers"],
        correct_answer=row["correct_answer"],
        alternative_answers=list(row["alternative_answers"] or []),
        topic=row["topic"],
        category=row["category"],
        difficulty=row["difficulty"],
        tags=list(row["tags"] or []),
        language_dependent=row["language_dependent"],
        age_appropriate=row["age_appropriate"],
        language=row["language"],
        pack_id=str(row["pack_id"]) if row["pack_id"] is not None else None,
        source=row["source"],
        source_url=row["source_url"],
        source_excerpt=row["source_excerpt"],
        review_status=row["review_status"],
        embedding=embedding,
        embedding_model=row["embedding_model"],
        embedding_dim=row["embedding_dim"],
        usage_count=row["usage_count"],
        created_at=row["created_at"],
        expires_at=row["expires_at"],
        freshness_tag=row["freshness_tag"],
        explanation=row["explanation"],
        media_url=row["media_url"],
        image_subtype=row["image_subtype"],
        generation_metadata=generation_metadata,
    )
