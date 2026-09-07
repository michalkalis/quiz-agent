"""Translation store: `question_translations` + `question_translation_corrections`
+ `questions.approved_languages` (#168 — batch translation pipeline SK/CS, T11).

Purely additive (DD3/DD4 "migrate before deploy"): two new tables plus one new
column that carries `NOT NULL DEFAULT '{}'`, so the *currently deployed* code —
which does not declare `approved_languages` — keeps running unchanged against
this schema. That is what makes migrate-then-deploy the safe order here; the
reverse order 500s every retrieval, English included, because
`questions_table` in `packages/shared` is an explicit column declaration.

`approved_languages` is a derived retrieval index, not the system of record:
`question_translations` is, and the column is written only by the pipeline in
the same transaction that flips a translation to `approved` (DD1). The GIN
index is what makes the `@>` serving filter usable on the hot path.

Unlike most migrations on this chain, `downgrade()` is implemented rather than
forward-only (R8): everything here is additive and drops cleanly, and a real
downgrade is what lets the up→down→up round-trip be verified on a scratch
database before the migration is applied to a live one. Recovery in production
is still a snapshot restore, not `alembic downgrade`.

Revision ID: c7e2b45a90d3
Revises: f2a91c4b8e57
Create Date: 2026-09-06
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "c7e2b45a90d3"
down_revision = "f2a91c4b8e57"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "question_translations",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("question_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("language", sa.String(length=16), nullable=False),
        sa.Column(
            "status",
            sa.String(length=16),
            nullable=False,
            server_default=sa.text("'pending'"),
        ),
        # ── Serve payload (mirrors serializers.py:143-152) ──
        sa.Column("question", sa.Text(), nullable=False),
        sa.Column(
            "possible_answers", postgresql.JSONB(astext_type=sa.Text()), nullable=True
        ),
        sa.Column("explanation", sa.Text(), nullable=True),
        sa.Column("headline_answer", sa.Text(), nullable=True),
        sa.Column("correct_answer", sa.Text(), nullable=False),
        sa.Column("correct_answer_key", sa.String(length=8), nullable=True),
        sa.Column(
            "alternative_answers",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
        # ── Provenance ──
        sa.Column("model", sa.String(length=128), nullable=False),
        sa.Column("prompt_version", sa.String(length=32), nullable=False),
        sa.Column("batch_id", sa.String(length=128), nullable=True),
        # NULL = cost not attributable to this row (e.g. a re-run off a cached
        # batch result); 0 is a real, different fact.
        sa.Column("cost_cents", sa.Numeric(precision=10, scale=4), nullable=True),
        # NOT NULL: the binding between an approved translation and the English
        # text it was approved against (DD3/F1). Without it a post-approval edit
        # to the source question leaves a silently wrong translation serving.
        sa.Column("source_hash", sa.String(length=64), nullable=False),
        # Guard results, blind-answerability outcome, MQM-Quiz findings and the
        # regional flag — one JSONB blob because nothing queries inside it.
        sa.Column(
            "verification",
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
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        # CASCADE, not SET NULL: a translation of a deleted question has no
        # meaning, and the production correction workflow is delete-then-
        # reimport (scripts/apply_corrections_production.py) — the cascade is
        # what makes that workflow safe by construction (DD3).
        sa.ForeignKeyConstraint(["question_id"], ["questions.id"], ondelete="CASCADE"),
        sa.CheckConstraint(
            "status IN ('pending','approved','rejected','stale')",
            name="ck_question_translations_status",
        ),
    )
    # One LIVE row per (question, language) — retranslation overwrites the row
    # and drops it back to `pending`, so the database, not the runner, is what
    # guarantees a language can never have two competing drafts.
    op.create_index(
        "uq_question_translations_question_language",
        "question_translations",
        ["question_id", "language"],
        unique=True,
    )
    # The coverage report (DD4 step-4 gate) counts approved rows per language.
    op.create_index(
        "ix_question_translations_language_status",
        "question_translations",
        ["language", "status"],
    )

    op.create_table(
        "question_translation_corrections",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("translation_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("field", sa.String(length=64), nullable=False),
        sa.Column("before", sa.Text(), nullable=True),
        sa.Column("after", sa.Text(), nullable=True),
        # MQM-Quiz category — the histogram this column feeds is what the
        # glossary loop is curated from, which is why corrections are their own
        # append-only table and not an in-place JSONB array (DD3).
        sa.Column("category", sa.String(length=64), nullable=False),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("source", sa.String(length=64), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.ForeignKeyConstraint(
            ["translation_id"], ["question_translations.id"], ondelete="CASCADE"
        ),
    )
    op.create_index(
        "ix_question_translation_corrections_translation_id",
        "question_translation_corrections",
        ["translation_id"],
    )
    op.create_index(
        "ix_question_translation_corrections_category",
        "question_translation_corrections",
        ["category"],
    )

    # DEFAULT '{}' (not NULL): every existing row becomes "approved in no
    # non-English language", which is exactly the pre-migration truth, and the
    # serving filter never has to reason about NULL.
    op.add_column(
        "questions",
        sa.Column(
            "approved_languages",
            postgresql.ARRAY(sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::text[]"),
        ),
    )
    op.create_index(
        "ix_questions_approved_languages",
        "questions",
        ["approved_languages"],
        postgresql_using="gin",
    )


def downgrade() -> None:
    op.drop_index("ix_questions_approved_languages", table_name="questions")
    op.drop_column("questions", "approved_languages")
    op.drop_table("question_translation_corrections")
    op.drop_table("question_translations")
