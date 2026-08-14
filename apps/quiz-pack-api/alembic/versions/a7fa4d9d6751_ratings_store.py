"""Canonical ratings store: `rating_batches` + `ratings` (issue #154).

Two new tables, nothing existing touched — a deploy running the previous build
against this schema is unaffected, so the migration can be applied before the
code that uses it (migrate-before-deploy).

Autogenerate additionally emitted `drop_index('ix_questions_embedding_ivfflat')`;
that was removed by hand. The pgvector ivfflat index is created by an earlier
migration with options SQLAlchemy's metadata cannot express, so every
autogenerate run "detects" it as removed — dropping it would silently destroy
the semantic-search index on `questions`.

Revision ID: a7fa4d9d6751
Revises: d5b0c93a71e4
Create Date: 2026-08-14
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "a7fa4d9d6751"
down_revision = "d5b0c93a71e4"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "rating_batches",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("title", sa.Text(), nullable=False),
        # Blinded, rater-visible questions.
        sa.Column(
            "questions",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
        # Server-only unblinding (arm, original question id, provenance).
        sa.Column(
            "mapping",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
    )

    op.create_table(
        "ratings",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("dedupe_key", sa.Text(), nullable=False),
        sa.Column("batch_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("blinded_qid", sa.String(length=32), nullable=True),
        sa.Column("question_id", sa.String(length=64), nullable=True),
        sa.Column("question_text", sa.Text(), nullable=False),
        sa.Column("rater", sa.String(length=128), nullable=False),
        sa.Column("score", sa.Numeric(precision=5, scale=2), nullable=False),
        sa.Column(
            "scale_min", sa.Integer(), nullable=False, server_default=sa.text("1")
        ),
        sa.Column(
            "scale_max", sa.Integer(), nullable=False, server_default=sa.text("10")
        ),
        sa.Column("reason", sa.Text(), nullable=True),
        sa.Column("source", sa.String(length=64), nullable=False),
        sa.Column(
            "rated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.Column("extra", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
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
        # A degenerate scale would make the export's normalisation divide by zero.
        sa.CheckConstraint("scale_max > scale_min", name="ck_ratings_scale_range"),
        sa.CheckConstraint(
            "score >= scale_min AND score <= scale_max", name="ck_ratings_score_range"
        ),
        sa.CheckConstraint(
            "source IN ('web','in-app') OR source LIKE 'backfill:%'",
            name="ck_ratings_source",
        ),
        # SET NULL, not CASCADE: deleting an experiment batch must not delete
        # the ratings it collected — the question text is snapshotted on the row.
        sa.ForeignKeyConstraint(
            ["batch_id"], ["rating_batches.id"], ondelete="SET NULL"
        ),
    )
    # UNIQUE: the upsert semantics ("same rater re-rates → update, don't
    # duplicate") are enforced by the database, not by a read-then-write race.
    op.create_index("ix_ratings_dedupe_key", "ratings", ["dedupe_key"], unique=True)
    op.create_index("ix_ratings_batch_id", "ratings", ["batch_id"])
    op.create_index("ix_ratings_question_id", "ratings", ["question_id"])
    op.create_index("ix_ratings_rater", "ratings", ["rater"])


def downgrade() -> None:
    # Forward-only per R8.
    pass
