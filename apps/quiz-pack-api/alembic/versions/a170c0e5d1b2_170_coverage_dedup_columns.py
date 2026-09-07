"""#170 coverage-driven dedup — 4 nullable columns + 2 btree indexes on `questions` (D8).

Purely additive; every existing row keeps NULLs and nothing in the pipeline
reads the new columns until its feature flag is ON (all default OFF), so the
migration can run before or after the code lands. NO backfill here — that is
`scripts/backfill_embedding_qa.py` (free `--answer-key-only` pass, paid QA
embedding pass) so a migration never makes a paid OpenAI call. NO vector
index on `embedding_qa` (D9: the corpus is in the low thousands, seq scan is
correct; revisit at > ~5 000 rows or on the ivfflat-scan warning).

- subtopic            VARCHAR(64)   — coverage cell (D1/D4), written at persist
- answer_key          VARCHAR(255)  — normalized answer for the per-category cap (D6)
- embedding_qa        VECTOR(1536)  — question+answer embedding, second column (D2)
- embedding_qa_model  VARCHAR(64)
- ix_questions_lang_category_subtopic   (language, category, subtopic)   — coverage map
- ix_questions_lang_category_answer_key (language, category, answer_key) — answer cap

Revision ID: a170c0e5d1b2
Revises: f2a91c4b8e57
Create Date: 2026-09-07
"""

import sqlalchemy as sa
from alembic import op
from pgvector.sqlalchemy import Vector

revision = "a170c0e5d1b2"
down_revision = "f2a91c4b8e57"
branch_labels = None
depends_on = None

EMBEDDING_DIM = 1536


def upgrade() -> None:
    op.add_column(
        "questions", sa.Column("subtopic", sa.String(length=64), nullable=True)
    )
    op.add_column(
        "questions", sa.Column("answer_key", sa.String(length=255), nullable=True)
    )
    op.add_column(
        "questions", sa.Column("embedding_qa", Vector(EMBEDDING_DIM), nullable=True)
    )
    op.add_column(
        "questions",
        sa.Column("embedding_qa_model", sa.String(length=64), nullable=True),
    )
    op.create_index(
        "ix_questions_lang_category_subtopic",
        "questions",
        ["language", "category", "subtopic"],
    )
    op.create_index(
        "ix_questions_lang_category_answer_key",
        "questions",
        ["language", "category", "answer_key"],
    )


def downgrade() -> None:
    op.drop_index("ix_questions_lang_category_answer_key", table_name="questions")
    op.drop_index("ix_questions_lang_category_subtopic", table_name="questions")
    op.drop_column("questions", "embedding_qa_model")
    op.drop_column("questions", "embedding_qa")
    op.drop_column("questions", "answer_key")
    op.drop_column("questions", "subtopic")
