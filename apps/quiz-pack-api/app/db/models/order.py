"""`generation_orders` ORM table (issue #33 Task 1.5).

`job_id` / `pack_id` FKs use `use_alter=True` because `generation_jobs` and
`question_packs` both FK back to orders — the migration creates orders first
without those constraints, then adds them after the other tables exist.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Optional

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Integer,
    String,
    Text,
    text,
)
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.orm import Mapped, mapped_column

from ..base import Base, UUIDPrimaryKeyMixin

ORDER_STATUSES = ("pending", "in_progress", "delivered", "failed", "refunded")


class GenerationOrder(Base, UUIDPrimaryKeyMixin):
    __tablename__ = "generation_orders"

    user_id: Mapped[Optional[str]] = mapped_column(String(128), nullable=True)
    transaction_id: Mapped[str] = mapped_column(
        String(128), nullable=False, unique=True
    )
    product_id: Mapped[str] = mapped_column(String(64), nullable=False)
    prompt: Mapped[str] = mapped_column(Text, nullable=False)
    category: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    theme: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    target_count: Mapped[int] = mapped_column(Integer, nullable=False)
    language: Mapped[str] = mapped_column(String(16), nullable=False)
    status: Mapped[str] = mapped_column(
        String(32), nullable=False, default="pending", server_default="pending"
    )
    job_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        PGUUID(as_uuid=True),
        ForeignKey(
            "generation_jobs.id",
            use_alter=True,
            name="fk_orders_job_id",
            ondelete="SET NULL",
        ),
        nullable=True,
    )
    pack_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        PGUUID(as_uuid=True),
        ForeignKey(
            "question_packs.id",
            use_alter=True,
            name="fk_orders_pack_id",
            ondelete="SET NULL",
        ),
        nullable=True,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=text("now()")
    )
    delivered_at: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    refund_eligible: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=text("false")
    )

    __table_args__ = (
        CheckConstraint(
            "status IN ('pending','in_progress','delivered','failed','refunded')",
            name="ck_orders_status",
        ),
    )
