"""core entities: questions, generation_orders, generation_jobs, question_packs

Issue #33 Task 1.5. Forward-only per R8 — `downgrade` is intentionally a no-op;
recovery from a bad migration = restore from Fly Postgres snapshot.

`generation_orders.job_id` / `pack_id` reference tables that themselves FK back
to orders, so those FKs are added in a second pass after every table exists.

Revision ID: 1c5e0fa7b3d4
Revises: 29f509ffa769
Create Date: 2026-05-11
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from pgvector.sqlalchemy import Vector
from sqlalchemy.dialects import postgresql

revision: str = "1c5e0fa7b3d4"
down_revision: Union[str, Sequence[str], None] = "29f509ffa769"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 1) generation_orders — no FKs to jobs/packs yet, they're added at the end.
    op.create_table(
        "generation_orders",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", sa.String(128), nullable=True),
        sa.Column("transaction_id", sa.String(128), nullable=False, unique=True),
        sa.Column("product_id", sa.String(64), nullable=False),
        sa.Column("prompt", sa.Text, nullable=False),
        sa.Column("category", sa.String(64), nullable=True),
        sa.Column("theme", sa.String(64), nullable=True),
        sa.Column("target_count", sa.Integer, nullable=False),
        sa.Column("language", sa.String(16), nullable=False),
        sa.Column(
            "status",
            sa.String(32),
            nullable=False,
            server_default="pending",
        ),
        sa.Column("job_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("pack_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.Column("delivered_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "refund_eligible",
            sa.Boolean,
            nullable=False,
            server_default=sa.text("false"),
        ),
        sa.CheckConstraint(
            "status IN ('pending','in_progress','delivered','failed','refunded')",
            name="ck_orders_status",
        ),
    )

    # 2) generation_jobs — FK back to orders is fine (orders already exists).
    op.create_table(
        "generation_jobs",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "order_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("generation_orders.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "status",
            sa.String(32),
            nullable=False,
            server_default="queued",
        ),
        sa.Column(
            "progress",
            sa.SmallInteger,
            nullable=False,
            server_default=sa.text("0"),
        ),
        sa.Column(
            "step_log",
            postgresql.JSONB,
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
        sa.Column(
            "total_cost_cents",
            sa.Integer,
            nullable=False,
            server_default=sa.text("0"),
        ),
        sa.Column(
            "retry_count",
            sa.Integer,
            nullable=False,
            server_default=sa.text("0"),
        ),
        sa.Column("error", sa.Text, nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.CheckConstraint(
            "status IN ('queued','sourcing','generating','critiquing','verifying',"
            "'scoring','persisting','done','failed')",
            name="ck_jobs_status",
        ),
        sa.CheckConstraint(
            "progress >= 0 AND progress <= 100",
            name="ck_jobs_progress",
        ),
    )

    # 3) question_packs — FK back to orders.
    op.create_table(
        "question_packs",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "order_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("generation_orders.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("user_id", sa.String(128), nullable=True),
        sa.Column("name", sa.Text, nullable=True),
        sa.Column("description", sa.Text, nullable=True),
        sa.Column("prompt", sa.Text, nullable=False),
        sa.Column("prompt_embedding", Vector(1536), nullable=True),
        sa.Column("category", sa.String(64), nullable=True),
        sa.Column("theme", sa.String(64), nullable=True),
        sa.Column("language", sa.String(16), nullable=False),
        sa.Column("generated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("actual_count", sa.Integer, nullable=True),
        sa.Column("target_count", sa.Integer, nullable=False),
    )

    # 4) questions — FK to packs (already exists).
    op.create_table(
        "questions",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("question", sa.Text, nullable=False),
        sa.Column("type", sa.String(32), nullable=False, server_default="text"),
        sa.Column("possible_answers", postgresql.JSONB, nullable=True),
        sa.Column("correct_answer", postgresql.JSONB, nullable=False),
        sa.Column(
            "alternative_answers",
            postgresql.JSONB,
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
        sa.Column("topic", sa.String(128), nullable=False),
        sa.Column("category", sa.String(64), nullable=False),
        sa.Column("difficulty", sa.String(16), nullable=False),
        sa.Column(
            "tags",
            postgresql.JSONB,
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
        sa.Column(
            "language_dependent",
            sa.Boolean,
            nullable=False,
            server_default=sa.text("false"),
        ),
        sa.Column("age_appropriate", sa.String(8), nullable=True),
        sa.Column("language", sa.String(16), nullable=True),
        sa.Column(
            "pack_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("question_packs.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("prompt_seed", sa.String(64), nullable=True),
        sa.Column("provenance", postgresql.JSONB, nullable=True),
        sa.Column(
            "source", sa.String(32), nullable=False, server_default="generated"
        ),
        sa.Column("source_url", sa.Text, nullable=True),
        sa.Column("source_excerpt", sa.Text, nullable=True),
        sa.Column(
            "review_status",
            sa.String(32),
            nullable=False,
            server_default="pending_review",
        ),
        sa.Column("embedding", Vector(1536), nullable=True),
        sa.Column("embedding_model", sa.String(64), nullable=True),
        sa.Column("embedding_dim", sa.Integer, nullable=True),
        sa.Column("cost_cents", sa.Integer, nullable=True),
        sa.Column(
            "usage_count",
            sa.Integer,
            nullable=False,
            server_default=sa.text("0"),
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("freshness_tag", sa.String(64), nullable=True),
        sa.Column("created_by", sa.String(64), nullable=True),
        sa.Column("reviewed_by", sa.String(64), nullable=True),
        sa.Column("reviewed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("review_notes", sa.Text, nullable=True),
        sa.Column("quality_ratings", postgresql.JSONB, nullable=True),
        sa.Column(
            "user_ratings",
            postgresql.JSONB,
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column("media_url", sa.Text, nullable=True),
        sa.Column("image_subtype", sa.String(32), nullable=True),
        sa.Column("media_duration_seconds", sa.Integer, nullable=True),
        sa.Column("explanation", sa.Text, nullable=True),
        sa.CheckConstraint(
            "review_status IN ('pending_review','approved','rejected','needs_revision')",
            name="ck_questions_review_status",
        ),
    )

    # 5) Indexes — btree partial, btree composite, ivfflat cosine.
    op.create_index(
        "ix_questions_pack_id",
        "questions",
        ["pack_id"],
        postgresql_where=sa.text("pack_id IS NOT NULL"),
    )
    op.create_index(
        "ix_questions_language_category_review_status",
        "questions",
        ["language", "category", "review_status"],
    )
    op.execute(
        "CREATE INDEX ix_questions_embedding_ivfflat ON questions "
        "USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)"
    )

    # 6) Add the orders → jobs / packs FKs now that both target tables exist.
    op.create_foreign_key(
        "fk_orders_job_id",
        "generation_orders",
        "generation_jobs",
        ["job_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_foreign_key(
        "fk_orders_pack_id",
        "generation_orders",
        "question_packs",
        ["pack_id"],
        ["id"],
        ondelete="SET NULL",
    )


def downgrade() -> None:
    # Forward-only per R8.
    pass
