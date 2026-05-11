"""`question_packs` ORM table (issue #33 Task 1.5).

`prompt_embedding` is the pgvector column used in Phase 3 for the C3 fact-pool
cache lookup (cosine ≥ 0.92 → reuse cached fact_ids); kept nullable in Phase 1
since the stub pipeline doesn't yet populate it.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Optional

from pgvector.sqlalchemy import Vector
from sqlalchemy import (
    DateTime,
    ForeignKey,
    Integer,
    String,
    Text,
)
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from ..base import Base, UUIDPrimaryKeyMixin
from .question import EMBEDDING_DIM


class QuestionPack(Base, UUIDPrimaryKeyMixin):
    __tablename__ = "question_packs"

    order_id: Mapped[uuid.UUID] = mapped_column(
        PGUUID(as_uuid=True),
        ForeignKey("generation_orders.id", ondelete="CASCADE"),
        nullable=False,
    )
    user_id: Mapped[Optional[str]] = mapped_column(String(128), nullable=True)
    name: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    description: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    prompt: Mapped[str] = mapped_column(Text, nullable=False)
    prompt_embedding = mapped_column(Vector(EMBEDDING_DIM), nullable=True)
    category: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    theme: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    language: Mapped[str] = mapped_column(String(16), nullable=False)
    generated_at: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    actual_count: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    target_count: Mapped[int] = mapped_column(Integer, nullable=False)
