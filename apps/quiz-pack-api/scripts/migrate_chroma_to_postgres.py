#!/usr/bin/env python3
"""ChromaDB approved questions → Postgres+pgvector migrator (issue #33, Task 1.7).

Reads the ``quiz_questions`` collection from a ChromaDB persist directory and
upserts each question into the quiz-pack-api ``questions`` table created in
Task 1.5. Embeddings are copied straight across (no re-embed: ChromaDB stores
the cached vectors that were generated when the question was approved).
Only rows whose source ``review_status`` is already ``approved`` are
migrated — a dev ``chroma_data`` dir mixes approved + ``pending_review`` in
one collection, and publishing unreviewed rows to the global library would be
a content-safety bug. Migrated rows are stamped ``review_status='approved'``
(a no-op normalisation) and ``pack_id=NULL`` per D7 (existing curated content
stays in the global library).

Idempotency
-----------
Legacy ChromaDB ids may not be UUIDs (e.g. ``kids_22``); the Task 1.5 seam
refuses them. This script imports ``_legacy_to_uuid`` from the Task 1.6
``migrate_pending_to_postgres`` sibling so a given legacy id maps to the same
Postgres row id across both migrations — a question that lived in both
``pending.db`` and ChromaDB collides on a single Postgres row.

On id conflict, the script upserts ``review_status``, ``pack_id``, ``question``,
``embedding`` (+ model/dim), and ``provenance`` — i.e. ChromaDB is treated as
the authoritative writer for approved questions. This satisfies the acceptance
test even when a row previously landed via 1.6 with ``review_status='pending_review'``.

Prod runbook (approach a — `fly ssh sftp get`, default)
-------------------------------------------------------
1. Pause backend writes that touch the chroma volume on ``quiz-agent`` (≤ 5 min).
2. ``fly ssh sftp shell -a quiz-agent`` then ``get -r /data/chroma_data ./prod_chroma_data``
   (or pull a tarball: ``fly ssh console -a quiz-agent -C 'tar czf - /data/chroma_data' > prod_chroma.tgz``).
3. ``python apps/quiz-pack-api/scripts/migrate_chroma_to_postgres.py \\
       --chroma-path ./prod_chroma_data \\
       --database-url "$PROD_DATABASE_URL" \\
       --dry-run``
4. Eyeball: dry-run count == ``SELECT count(*) FROM collection`` on chroma.
   Then rerun with ``--execute``.
5. Verify: ``psql $PROD_DATABASE_URL -c \\
       \"SELECT count(*) FROM questions WHERE pack_id IS NULL AND review_status='approved'\"`` \\
       equals the ChromaDB count.

Approach (b) — run inside ``quiz-agent`` via ``fly ssh console`` with
``DATABASE_URL`` temporarily set as a secret on that app — works too, but
adds infra friction (cross-app secret juggling) for a one-shot migration. We
prefer (a), consistent with how Task 1.6 ran.

Per memory ``feedback_qgen_import_cwd``: run from ``apps/quiz-pack-api/`` cwd so
``app.*`` and ``quiz_shared`` resolve from this repo's workspace setup.

Usage
-----
::

    # Local dry-run against the dev chroma volume
    python apps/quiz-pack-api/scripts/migrate_chroma_to_postgres.py --dry-run

    # Local execute
    python apps/quiz-pack-api/scripts/migrate_chroma_to_postgres.py --execute

    # Prod execute (after sftp pull)
    python apps/quiz-pack-api/scripts/migrate_chroma_to_postgres.py \\
        --chroma-path ./prod_chroma_data \\
        --database-url "$PROD_DATABASE_URL" --execute
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Sequence

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.image_generation.env_loader import load_env  # noqa: E402

load_env()

from sqlalchemy import select, text  # noqa: E402
from sqlalchemy.dialects.postgresql import insert as pg_insert  # noqa: E402
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine  # noqa: E402

from app.db import QuestionRow, engine, normalize_async_url, question_to_row  # noqa: E402
from quiz_shared.database.question_store import ChromaDBQuestionStore  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402

# Reuse the 1.6 legacy-id → UUID mapping so a question present in both
# pending.db and ChromaDB resolves to the same Postgres row id.
from migrate_pending_to_postgres import (  # noqa: E402
    EMBEDDING_DIM,
    EMBEDDING_MODEL,
    _legacy_to_uuid,
    _row_to_insert_dict,
)

logger = logging.getLogger("migrate_chroma")

DEFAULT_CHROMA_PATH = Path("apps/quiz-agent/chroma_data")
CHROMA_COLLECTION = "quiz_questions"
# Pull rows in pages so a large collection doesn't load everything into RAM.
PAGE_SIZE = 500


def _read_chroma_rows(chroma_path: Path) -> Iterable[Dict[str, Any]]:
    """Yield ``{id, document, metadata, embedding}`` per ChromaDB row.

    Imported lazily so the script can fail-fast with a clear error if chromadb
    isn't installed (e.g. running inside the quiz-pack-api prod image, which
    intentionally excludes chromadb — see Dockerfile comment).
    """
    try:
        import chromadb  # noqa: F401
    except ImportError as exc:
        raise SystemExit(
            "chromadb is required to read ChromaDB. Install it locally or "
            "run this script from a dev env that has quiz-shared installed "
            "(chromadb is declared there)."
        ) from exc

    client = chromadb.PersistentClient(path=str(chroma_path))
    collection = client.get_collection(CHROMA_COLLECTION)
    total = collection.count()
    logger.info("ChromaDB collection %r contains %d row(s)", CHROMA_COLLECTION, total)

    offset = 0
    while offset < total:
        page = collection.get(
            limit=PAGE_SIZE,
            offset=offset,
            include=["embeddings", "documents", "metadatas"],
        )
        ids = page.get("ids") or []
        documents = page.get("documents") or []
        metadatas = page.get("metadatas") or []
        embeddings = page.get("embeddings")
        for i, qid in enumerate(ids):
            embedding = None
            if embeddings is not None and i < len(embeddings):
                vec = embeddings[i]
                if vec is not None:
                    embedding = [float(x) for x in vec]
            yield {
                "id": qid,
                "document": documents[i] if i < len(documents) else "",
                "metadata": metadatas[i] if i < len(metadatas) else {},
                "embedding": embedding,
            }
        offset += len(ids)
        if not ids:
            break


def _build_question(row: Dict[str, Any]) -> Question:
    """Convert a raw ChromaDB row into an ``approved`` Pydantic ``Question``."""
    legacy_id = row["id"]
    target_id = str(_legacy_to_uuid(legacy_id))

    # Single source of truth for metadata → Question is the existing store
    # helper; we only override the fields 1.7 declares authoritative.
    question = ChromaDBQuestionStore._metadata_to_question(
        target_id,
        row["document"],
        row["metadata"] or {},
        embedding=row["embedding"],
    )

    question.review_status = "approved"
    question.pack_id = None
    # Default language to English if the legacy row didn't track it.
    if question.language is None:
        question.language = "en"
    # Tag the embedding's provenance so vector queries can filter by model.
    if question.embedding is not None:
        if question.embedding_model is None:
            question.embedding_model = EMBEDDING_MODEL
        if question.embedding_dim is None:
            question.embedding_dim = len(question.embedding)

    # Preserve the legacy chroma id alongside any legacy_id from 1.6 so the
    # round-trip is traceable. provenance.extra is the loss-tolerant junk
    # drawer per GenerationProvenance._absorb_unknown_keys.
    if question.generation_metadata is not None:
        extra = dict(question.generation_metadata.extra or {})
        extra.setdefault("legacy_id", legacy_id)
        extra.setdefault("legacy_source", "chroma")
        question.generation_metadata.extra = extra

    return question


def _upsert_columns() -> List[str]:
    """Columns ChromaDB is authoritative for on conflict (id match)."""
    return [
        "review_status",
        "pack_id",
        "question",
        "embedding",
        "embedding_model",
        "embedding_dim",
        "provenance",
    ]


async def _existing_ids(session: AsyncSession, ids: Sequence[str]) -> set[str]:
    if not ids:
        return set()
    import uuid as _uuid
    uuids = [_uuid.UUID(i) for i in ids]
    result = await session.execute(
        select(QuestionRow.id).where(QuestionRow.id.in_(uuids))
    )
    return {str(r[0]) for r in result.all()}


async def _run(args: argparse.Namespace) -> int:
    chroma_path = Path(args.chroma_path)
    if not chroma_path.exists():
        logger.error("ChromaDB path %s does not exist", chroma_path)
        return 1

    rows = list(_read_chroma_rows(chroma_path))
    if not rows:
        logger.info("ChromaDB collection is empty; nothing to migrate.")

    questions: List[Question] = []
    skipped_no_embedding = 0
    skipped_not_approved = 0
    for row in rows:
        if (row.get("metadata") or {}).get("review_status") != "approved":
            skipped_not_approved += 1
            continue
        if row["embedding"] is None:
            skipped_no_embedding += 1
            logger.warning(
                "Skipping %s — ChromaDB row has no embedding (would need re-embed; "
                "out of scope for 1.7).", row["id"],
            )
            continue
        questions.append(_build_question(row))

    if args.database_url:
        async_engine = create_async_engine(
            normalize_async_url(args.database_url), future=True
        )
        owned_engine = True
    else:
        async_engine = engine
        owned_engine = False

    try:
        async with AsyncSession(async_engine, expire_on_commit=False) as session:
            existing = await _existing_ids(session, [q.id for q in questions])
        new_rows = [q for q in questions if q.id not in existing]
        overwrites = [q for q in questions if q.id in existing]

        print("── ChromaDB → Postgres summary ──────────────────")
        print(f"ChromaDB rows read:              {len(rows)}")
        print(f"Skipped (not approved):          {skipped_not_approved}")
        print(f"Skipped (no embedding):          {skipped_no_embedding}")
        print(f"Questions to migrate:            {len(questions)}")
        print(f"  ↳ new inserts:                 {len(new_rows)}")
        print(f"  ↳ upserts of existing rows:    {len(overwrites)}")

        if args.dry_run or not args.execute:
            return 0

        if not questions:
            print("Nothing to write.")
            return 0

        upsert_cols = _upsert_columns()
        async with async_engine.begin() as conn:
            # R7 belt-and-braces: even though 1.5 already built the ivfflat
            # index, set maintenance_work_mem in case Postgres rebuilds or
            # reindexes during a bulk upsert. Harmless if unused.
            await conn.execute(text("SET maintenance_work_mem = '128MB'"))

            payload = [
                _row_to_insert_dict(question_to_row(q)) for q in questions
            ]
            stmt = pg_insert(QuestionRow.__table__).values(payload)
            update_set = {c: getattr(stmt.excluded, c) for c in upsert_cols}
            stmt = stmt.on_conflict_do_update(
                index_elements=["id"], set_=update_set
            )
            result = await conn.execute(stmt)
            affected = result.rowcount or 0

        print("── result ───────────────────────────────────────")
        print(f"Rows touched (insert + update): {affected}")
        return 0
    finally:
        if owned_engine:
            await async_engine.dispose()


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )
    parser = argparse.ArgumentParser(
        description="Migrate ChromaDB approved questions into Postgres+pgvector.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--chroma-path", default=str(DEFAULT_CHROMA_PATH),
        help=f"Path to a ChromaDB persist dir (default: {DEFAULT_CHROMA_PATH}).",
    )
    parser.add_argument(
        "--database-url",
        help="Postgres URL (libpq or asyncpg form). Defaults to app.config.Settings.",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true",
                      help="Print counts; perform no writes (default).")
    mode.add_argument("--execute", action="store_true",
                      help="Perform upserts.")
    args = parser.parse_args()
    if not args.dry_run and not args.execute:
        args.dry_run = True
    return asyncio.run(_run(args))


if __name__ == "__main__":
    sys.exit(main())
