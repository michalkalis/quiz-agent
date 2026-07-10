"""`questions` ORM table + Pydantic↔ORM seam (issue #33 Task 1.5).

The seam is explicit on purpose: Pydantic stays the wire/domain layer and
SQLAlchemy stays persistence. No `Question.model_dump()` shortcut — fields
are mapped one-by-one so each schema change is reviewed at the boundary.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from pgvector.sqlalchemy import Vector
from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from quiz_shared.models.question import GenerationProvenance, Question

from ..base import Base, UUIDPrimaryKeyMixin

EMBEDDING_DIM = 1536
REVIEW_STATUSES = ("pending_review", "approved", "rejected", "needs_revision", "archived")


class QuestionRow(Base, UUIDPrimaryKeyMixin):
    """Persistence shape for `quiz_shared.models.question.Question`.

    Named `QuestionRow` to keep the Pydantic name unambiguous at the seam.
    """

    __tablename__ = "questions"

    question: Mapped[str] = mapped_column(Text, nullable=False)
    type: Mapped[str] = mapped_column(String(32), nullable=False, default="text")
    possible_answers: Mapped[Optional[Dict[str, str]]] = mapped_column(JSONB, nullable=True)
    correct_answer: Mapped[Any] = mapped_column(JSONB, nullable=False)
    alternative_answers: Mapped[List[str]] = mapped_column(
        JSONB, nullable=False, default=list, server_default=text("'[]'::jsonb")
    )
    topic: Mapped[str] = mapped_column(String(128), nullable=False)
    category: Mapped[str] = mapped_column(String(64), nullable=False)
    difficulty: Mapped[str] = mapped_column(String(16), nullable=False)
    tags: Mapped[List[str]] = mapped_column(
        JSONB, nullable=False, default=list, server_default=text("'[]'::jsonb")
    )
    language_dependent: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=text("false")
    )
    age_appropriate: Mapped[Optional[str]] = mapped_column(String(8), nullable=True)
    language: Mapped[Optional[str]] = mapped_column(String(16), nullable=True)
    pack_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        PGUUID(as_uuid=True),
        ForeignKey("question_packs.id", ondelete="SET NULL"),
        nullable=True,
    )
    prompt_seed: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    provenance: Mapped[Optional[Dict[str, Any]]] = mapped_column(JSONB, nullable=True)
    source: Mapped[str] = mapped_column(String(32), nullable=False, default="generated")
    source_url: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    source_excerpt: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    review_status: Mapped[str] = mapped_column(
        String(32), nullable=False, default="pending_review"
    )
    embedding = mapped_column(Vector(EMBEDDING_DIM), nullable=True)
    embedding_model: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    embedding_dim: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    cost_cents: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    usage_count: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default=text("0")
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )
    expires_at: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    freshness_tag: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)

    # Fields not in the schema sketch but present in Pydantic `Question`.
    # Kept as plain columns so round-trip is value-equal without leaning on
    # `provenance` as a junk drawer.
    created_by: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    reviewed_by: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    reviewed_at: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    review_notes: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    quality_ratings: Mapped[Optional[Dict[str, int]]] = mapped_column(JSONB, nullable=True)
    user_ratings: Mapped[Dict[str, int]] = mapped_column(
        JSONB, nullable=False, default=dict, server_default=text("'{}'::jsonb")
    )
    media_url: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    image_subtype: Mapped[Optional[str]] = mapped_column(String(32), nullable=True)
    media_duration_seconds: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    explanation: Mapped[Optional[str]] = mapped_column(Text, nullable=True)

    __table_args__ = (
        CheckConstraint(
            "review_status IN ('pending_review','approved','rejected','needs_revision','archived')",
            name="ck_questions_review_status",
        ),
        Index(
            "ix_questions_pack_id",
            "pack_id",
            postgresql_where=text("pack_id IS NOT NULL"),
        ),
        Index(
            "ix_questions_language_category_review_status",
            "language",
            "category",
            "review_status",
        ),
    )


# ── Pydantic ↔ ORM seam ────────────────────────────────────────────────────


def _ensure_utc(dt: Optional[datetime]) -> Optional[datetime]:
    """Promote naive datetimes to UTC-aware. TIMESTAMPTZ stores tz-aware only."""
    if dt is None:
        return None
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def _coerce_uuid(value: Optional[str]) -> Optional[uuid.UUID]:
    """Strict UUID parsing for Pydantic id strings.

    Legacy non-UUID ids (e.g. ``q_abc123``) are a Task 1.6 migration concern;
    this seam refuses them on purpose so callers don't silently lose identity.
    """
    if value is None:
        return None
    return uuid.UUID(value)


def question_to_row(q: Question) -> QuestionRow:
    """Pydantic `Question` → ORM `QuestionRow`. Field-by-field, no shortcuts."""
    row = QuestionRow(
        question=q.question,
        type=q.type,
        possible_answers=q.possible_answers,
        correct_answer=q.correct_answer,
        alternative_answers=list(q.alternative_answers),
        topic=q.topic,
        category=q.category,
        difficulty=q.difficulty,
        tags=list(q.tags),
        language_dependent=q.language_dependent,
        age_appropriate=q.age_appropriate,
        language=q.language,
        pack_id=_coerce_uuid(q.pack_id),
        prompt_seed=q.prompt_seed,
        provenance=(
            q.generation_metadata.model_dump(mode="json")
            if q.generation_metadata is not None
            else None
        ),
        source=q.source,
        source_url=q.source_url,
        source_excerpt=q.source_excerpt,
        review_status=q.review_status,
        embedding=list(q.embedding) if q.embedding is not None else None,
        embedding_model=q.embedding_model,
        embedding_dim=q.embedding_dim,
        cost_cents=q.cost_cents,
        usage_count=q.usage_count,
        created_at=_ensure_utc(q.created_at) or datetime.now(timezone.utc),
        expires_at=_ensure_utc(q.expires_at),
        freshness_tag=q.freshness_tag,
        created_by=q.created_by,
        reviewed_by=q.reviewed_by,
        reviewed_at=_ensure_utc(q.reviewed_at),
        review_notes=q.review_notes,
        quality_ratings=q.quality_ratings,
        user_ratings=dict(q.user_ratings),
        media_url=q.media_url,
        image_subtype=q.image_subtype,
        media_duration_seconds=q.media_duration_seconds,
        explanation=q.explanation,
    )
    parsed = _coerce_uuid(q.id)
    if parsed is not None:
        row.id = parsed
    return row


def row_to_question(row: QuestionRow) -> Question:
    """ORM `QuestionRow` → Pydantic `Question`."""
    embedding = None
    if row.embedding is not None:
        # pgvector returns numpy arrays by default; normalise to list[float].
        embedding = [float(x) for x in row.embedding]
    return Question(
        id=str(row.id),
        question=row.question,
        type=row.type,
        possible_answers=row.possible_answers,
        correct_answer=row.correct_answer,
        alternative_answers=list(row.alternative_answers or []),
        topic=row.topic,
        category=row.category,
        difficulty=row.difficulty,
        tags=list(row.tags or []),
        language_dependent=row.language_dependent,
        age_appropriate=row.age_appropriate,
        language=row.language,
        pack_id=str(row.pack_id) if row.pack_id is not None else None,
        prompt_seed=row.prompt_seed,
        generation_metadata=(
            GenerationProvenance.model_validate(row.provenance)
            if row.provenance is not None
            else None
        ),
        source=row.source,
        source_url=row.source_url,
        source_excerpt=row.source_excerpt,
        review_status=row.review_status,
        embedding=embedding,
        embedding_model=row.embedding_model,
        embedding_dim=row.embedding_dim,
        cost_cents=row.cost_cents,
        usage_count=row.usage_count,
        created_at=row.created_at,
        expires_at=row.expires_at,
        freshness_tag=row.freshness_tag,
        created_by=row.created_by,
        reviewed_by=row.reviewed_by,
        reviewed_at=row.reviewed_at,
        review_notes=row.review_notes,
        quality_ratings=row.quality_ratings,
        user_ratings=dict(row.user_ratings or {}),
        media_url=row.media_url,
        image_subtype=row.image_subtype,
        media_duration_seconds=row.media_duration_seconds,
        explanation=row.explanation,
    )
