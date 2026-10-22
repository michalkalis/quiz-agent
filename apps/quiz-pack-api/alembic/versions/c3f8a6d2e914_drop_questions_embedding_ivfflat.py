"""Drop `ix_questions_embedding_ivfflat` — vector search goes back to exact.

The index was created in May on an EMPTY `questions` table (lists = 100), so
its centroids were never trained on real data, and pgvector's default
`ivfflat.probes = 1` scans one list of 100. Once the corpus grew (~3.4k rows,
2026-10-22) the planner started picking it for every `ORDER BY embedding <=> q
LIMIT n` query, and recall collapsed (measured on prod, read-only):

- live quiz retrieval (`search`, approved / en / corpus) asked for 50
  candidates and got 1-11 back; with exact search it gets 50;
- generation dedup (`find_duplicates`) missed a near-verbatim Mansa Musa
  paraphrase of an approved question; on the 2026-10-01 batch the cosine check
  caught 0 of 80 hand-dropped duplicates, 10 of 80 with exact search.

At this size an exact scan is ~20 ms for the whole table, and pgvector's own
guidance is exact search for small tables. An approximate index only pays off
far beyond today's corpus, and with WHERE filters it needs iterative scans to
keep recall — revisit then, with a recall check, not before.

Revision ID: c3f8a6d2e914
Revises: b207e5a0c1d2
Create Date: 2026-10-22
"""

from alembic import op

revision = "c3f8a6d2e914"
down_revision = "b207e5a0c1d2"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_questions_embedding_ivfflat")


def downgrade() -> None:
    op.execute(
        "CREATE INDEX ix_questions_embedding_ivfflat ON questions "
        "USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)"
    )
