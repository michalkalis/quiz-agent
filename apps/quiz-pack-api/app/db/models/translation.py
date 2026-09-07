"""`question_translations` + `question_translation_corrections` ORM tables
(#168 — batch translation pipeline SK/CS, DD3).

The system of record for per-(question, language) translation state. Only an
`approved` row may be served (locked decision 2 — no serve-time LLM translation,
no runtime English fallback), and `questions.approved_languages` is a *derived*
retrieval index over these rows, not a second source of truth: it exists solely
because the pgvector filter surface is flat single-column equality with no
joins, so the serving gate cannot join to this table (DD1).

One live row per (question, language): retranslation overwrites the row and
drops it back to `pending`. Superseded machine drafts have no consumer, so
there is deliberately no version table — the *human* edit history that does
have a consumer lives in `QuestionTranslationCorrection`, which is append-only
because the glossary loop queries a category histogram and in-place edits would
erase it.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Any, Optional

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Numeric,
    String,
    Text,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from ..base import Base, UUIDPrimaryKeyMixin

# `pending` = drafted, gate not passed · `approved` = servable · `rejected` =
# the gate or a human refused it · `stale` = the English source changed after
# approval (source_hash mismatch), so the row must stop serving until retranslated.
TRANSLATION_STATUSES = ("pending", "approved", "rejected", "stale")


class QuestionTranslation(Base, UUIDPrimaryKeyMixin):
    """One question's translation into one language, plus how it was verified."""

    __tablename__ = "question_translations"

    question_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True),
        # CASCADE: a translation of a deleted question has no meaning, and the
        # production correction workflow is delete-then-reimport — the cascade
        # is what makes that workflow safe without a reconcile step (DD3).
        ForeignKey("questions.id", ondelete="CASCADE"),
        nullable=False,
    )
    language: Mapped[str] = mapped_column(String(16), nullable=False)
    status: Mapped[str] = mapped_column(
        String(16), nullable=False, default="pending", server_default=text("'pending'")
    )

    # ── Serve payload: exactly the record `serializers.py:143-152` returns ──
    question: Mapped[str] = mapped_column(Text, nullable=False)
    possible_answers: Mapped[Optional[dict[str, str]]] = mapped_column(
        JSONB, nullable=True
    )
    explanation: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    headline_answer: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    correct_answer: Mapped[str] = mapped_column(Text, nullable=False)
    # MCQ option key ("a"/"b"/…). Kept alongside the display text because the
    # answerability comparator matches on the KEY, not the option text (DD13).
    correct_answer_key: Mapped[Optional[str]] = mapped_column(String(8), nullable=True)
    # Not an oversight (DD3/C1): `AnswerEvaluator` reads accepted alternates in
    # BOTH grading paths, so storing only the primary answer would score a
    # Slovak free-text reply against English alternates and mark it wrong.
    alternative_answers: Mapped[list[str]] = mapped_column(
        JSONB, nullable=False, default=list, server_default=text("'[]'::jsonb")
    )

    # ── Provenance ──
    model: Mapped[str] = mapped_column(String(128), nullable=False)
    prompt_version: Mapped[str] = mapped_column(String(32), nullable=False)
    batch_id: Mapped[Optional[str]] = mapped_column(String(128), nullable=True)
    # Numeric, not Integer: one translation costs a fraction of a cent, and
    # integer cents would round the whole corpus to zero. NULL = not
    # attributable to this row; 0 is a different, real fact.
    cost_cents: Mapped[Optional[Decimal]] = mapped_column(
        Numeric(10, 4), nullable=True
    )
    # sha256 over a canonical dump of exactly the translated source fields
    # (DD3/F1). NOT NULL: without it, an English edit after approval leaves a
    # silently wrong translation serving with nothing able to detect it.
    source_hash: Mapped[str] = mapped_column(String(64), nullable=False)

    # Guard results, blind-answerability outcome, MQM-Quiz findings, regional
    # flag. JSONB because nothing queries inside it — the gate's *verdict* is
    # `status`; this is the evidence behind it.
    verification: Mapped[dict[str, Any]] = mapped_column(
        JSONB, nullable=False, default=dict, server_default=text("'{}'::jsonb")
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )

    __table_args__ = (
        CheckConstraint(
            "status IN ('pending','approved','rejected','stale')",
            name="ck_question_translations_status",
        ),
        # UNIQUE so "one live row per (question, language)" is a database
        # invariant, not a convention the runner is trusted to keep.
        Index(
            "uq_question_translations_question_language",
            "question_id",
            "language",
            unique=True,
        ),
        # The DD4 coverage gate counts approved rows per language.
        Index("ix_question_translations_language_status", "language", "status"),
    )


class QuestionTranslationCorrection(Base, UUIDPrimaryKeyMixin):
    """One human edit to one translated field — append-only, never updated."""

    __tablename__ = "question_translation_corrections"

    translation_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True),
        ForeignKey("question_translations.id", ondelete="CASCADE"),
        nullable=False,
    )
    field: Mapped[str] = mapped_column(String(64), nullable=False)
    before: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    after: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    # MQM-Quiz category. The histogram over this column is what the reviewed
    # glossary files (`sk.json`/`cs.json`) are curated from — the glossary is
    # never auto-derived, or unreviewed corrections re-enter the pipeline.
    category: Mapped[str] = mapped_column(String(64), nullable=False)
    note: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    source: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )

    __table_args__ = (
        Index(
            "ix_question_translation_corrections_translation_id", "translation_id"
        ),
        Index("ix_question_translation_corrections_category", "category"),
    )


__all__ = [
    "QuestionTranslation",
    "QuestionTranslationCorrection",
    "TRANSLATION_STATUSES",
]
