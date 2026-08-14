"""`rating_batches` + `ratings` ORM tables (issue #154).

The canonical store for founder/multi-rater question ratings, replacing the
throwaway `rating.html` + localStorage + manual-JSON-paste loop (one round of
which survived only as a truncated PDF).

Blinding is a server-side property here, not a file-handling convention:
`RatingBatch.questions` is the blinded payload the page may see, and
`RatingBatch.mapping` (arm, original question id, provenance) never leaves the
server. Keeping both on one row is what makes the served page structurally
unable to leak the arm — there is no code path that hands `mapping` to a
template or a response model.

`Rating` is upsert-by-`dedupe_key`, not append-only: last write wins per
(batch, blinded question, rater) or (question, rater), and `updated_at` marks
a re-rate. History of superseded scores is deliberately NOT kept — a rater
fixing a slip should not skew the correlation analysis this store feeds.
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
    Integer,
    Numeric,
    String,
    Text,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from ..base import Base, UUIDPrimaryKeyMixin

# `source` values: where the rating came from. `backfill:<round>` (#156) is
# open-ended by design — the round label is the provenance.
RATING_SOURCES = ("web", "in-app")


class RatingBatch(Base, UUIDPrimaryKeyMixin):
    """A blind rating round: the questions shown + the mapping that unblinds them."""

    __tablename__ = "rating_batches"

    title: Mapped[str] = mapped_column(Text, nullable=False)
    # Blinded, rater-visible payload: [{"qid": "q01", "question": ..., "answer":
    # ..., "meta": {...}}]. Never contains arm / provenance fields.
    questions: Mapped[list[dict[str, Any]]] = mapped_column(
        JSONB, nullable=False, default=list, server_default=text("'[]'::jsonb")
    )
    # Server-only unblinding: {"q01": {"arm": ..., "original_id": ..., ...}}.
    mapping: Mapped[dict[str, Any]] = mapped_column(
        JSONB, nullable=False, default=dict, server_default=text("'{}'::jsonb")
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )


class Rating(Base, UUIDPrimaryKeyMixin):
    """One rater's current score for one question."""

    __tablename__ = "ratings"

    # Identity of "the same rating rated again". Constructed by the writer:
    #   web     -> "web:{batch_id}:{qid}:{rater}"
    #   in-app  -> "inapp:{question_id}:{rater}"
    #   #156    -> "backfill:{round}:..."
    # UNIQUE so the upsert is enforced by the database, not by a read-then-write
    # race in the route.
    dedupe_key: Mapped[str] = mapped_column(
        Text, nullable=False, unique=True, index=True
    )

    batch_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        PGUUID(as_uuid=True),
        ForeignKey("rating_batches.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    blinded_qid: Mapped[Optional[str]] = mapped_column(String(32), nullable=True)
    # Deliberately NOT a FK to `questions` and NOT a UUID column: batch
    # questions come from dry-run pipeline output that was never persisted, and
    # #156 backfills historical rounds whose ids may not be UUIDs at all. A
    # rating must survive its question being archived or never stored.
    question_id: Mapped[Optional[str]] = mapped_column(
        String(64), nullable=True, index=True
    )
    # Snapshot: the export must stay readable when the question is gone.
    question_text: Mapped[str] = mapped_column(Text, nullable=False)

    rater: Mapped[str] = mapped_column(String(128), nullable=False, index=True)
    # Numeric, not Integer: historical rounds carry half-point scores, and the
    # export normalises across scales anyway.
    score: Mapped[Decimal] = mapped_column(Numeric(5, 2), nullable=False)
    scale_min: Mapped[int] = mapped_column(
        Integer, nullable=False, default=1, server_default=text("1")
    )
    scale_max: Mapped[int] = mapped_column(
        Integer, nullable=False, default=10, server_default=text("10")
    )
    reason: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    source: Mapped[str] = mapped_column(String(64), nullable=False)
    rated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )
    extra: Mapped[Optional[dict[str, Any]]] = mapped_column(JSONB, nullable=True)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )

    __table_args__ = (
        # A degenerate scale would make the export's normalisation divide by
        # zero — reject it at write time instead.
        CheckConstraint("scale_max > scale_min", name="ck_ratings_scale_range"),
        CheckConstraint(
            "score >= scale_min AND score <= scale_max", name="ck_ratings_score_range"
        ),
        CheckConstraint(
            "source IN ('web','in-app') OR source LIKE 'backfill:%'",
            name="ck_ratings_source",
        ),
    )
