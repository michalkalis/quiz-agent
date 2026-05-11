#!/usr/bin/env python3
"""SQLite ``pending.db`` → Postgres ``questions`` migrator (issue #33, Task 1.6).

Reads pre-approval ``Question`` rows from one or more SQLite files (the legacy
``pending_store`` shape from issue #22) and writes them to the quiz-pack-api
Postgres ``questions`` table created in Task 1.5. Embeds rows that lack a
cached vector (OpenAI ``text-embedding-3-small``, batched at 100 inputs per
request) and is idempotent on the primary key.

Idempotency
-----------
Legacy ids like ``kids_22`` are not UUIDs; the Task 1.5 ORM seam refuses them
on purpose. This script derives a stable UUIDv5 from ``NAMESPACE_LEGACY_PENDING``
and the legacy id, so the same SQLite input always produces the same Postgres
row id — a second ``--execute`` produces zero inserts. The original SQLite id
is preserved at ``generation_metadata.extra.legacy_id`` for traceability.

Prod runbook (approach a — `fly ssh sftp get`)
----------------------------------------------
1. Freeze /import writes on the question-generator web UI (≤ 5 min window).
2. ``fly ssh sftp get /data/pending.db ./prod_pending.db -a quiz-agent``
3. ``python apps/quiz-pack-api/scripts/migrate_pending_to_postgres.py \\
       --sqlite-path ./prod_pending.db \\
       --database-url "$PROD_DATABASE_URL" \\
       --dry-run``
4. Eyeball the counts. If they match
   ``sqlite3 prod_pending.db 'SELECT COUNT(*) FROM pending_questions;'``,
   rerun the command with ``--execute``.
5. Verify: ``SELECT count(*) FROM questions WHERE embedding IS NULL`` → 0.

Approach (b) — ``fly machine run`` on quiz-pack-api with the quiz-agent volume
mounted read-only — is documented in the issue but adds infra friction. We
prefer (a) for the one-shot Phase 1 migration.

Usage
-----
::

    # Local dry-run (uses DATABASE_URL from .env)
    python apps/quiz-pack-api/scripts/migrate_pending_to_postgres.py --dry-run

    # Local execute with explicit SQLite file(s)
    python apps/quiz-pack-api/scripts/migrate_pending_to_postgres.py \\
        --sqlite-path apps/quiz-pack-api/data/pending.db --execute

    # Prod execute against the Fly Postgres instance
    python apps/quiz-pack-api/scripts/migrate_pending_to_postgres.py \\
        --sqlite-path ./prod_pending.db \\
        --database-url "$PROD_DATABASE_URL" --execute
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sqlite3
import sys
import uuid
from pathlib import Path
from typing import Iterable, List, Sequence

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.image_generation.env_loader import load_env  # noqa: E402

load_env()

from openai import OpenAI  # noqa: E402
from sqlalchemy import select  # noqa: E402
from sqlalchemy.dialects.postgresql import insert as pg_insert  # noqa: E402
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine  # noqa: E402

from app.db import QuestionRow, engine, normalize_async_url, question_to_row  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402

logger = logging.getLogger("migrate_pending")

# Stable UUIDv5 namespace for legacy SQLite ids. Random-once, never change —
# rotating this breaks idempotency.
NAMESPACE_LEGACY_PENDING = uuid.UUID("e7b8a0e4-1c0c-4f7f-8e9d-1a1a3a4b5c6d")

DEFAULT_SQLITE_PATHS = [
    ROOT / "pending.db",
    ROOT / "data" / "pending.db",
    Path.cwd() / "pending.db",
]

EMBEDDING_MODEL = "text-embedding-3-small"
EMBEDDING_DIM = 1536


def _legacy_to_uuid(legacy_id: str) -> uuid.UUID:
    try:
        return uuid.UUID(legacy_id)
    except (ValueError, AttributeError):
        return uuid.uuid5(NAMESPACE_LEGACY_PENDING, f"pending:{legacy_id}")


def _load_pending_rows(sqlite_path: Path) -> Iterable[tuple[str, dict]]:
    """Yield ``(legacy_id, data_dict)`` from a ``pending_questions`` table."""
    conn = sqlite3.connect(f"file:{sqlite_path}?mode=ro", uri=True)
    try:
        cur = conn.execute("SELECT id, data_json FROM pending_questions")
        for legacy_id, data_json in cur:
            yield legacy_id, json.loads(data_json)
    finally:
        conn.close()


def _build_question(legacy_id: str, raw: dict) -> Question:
    """Translate a SQLite row dict into a Pydantic ``Question`` with defaults set."""
    target_id = str(_legacy_to_uuid(legacy_id))

    provenance = raw.get("generation_metadata") or {}
    if isinstance(provenance, dict):
        extra = dict(provenance.get("extra") or {})
        extra.setdefault("legacy_id", legacy_id)
        provenance = {**provenance, "extra": extra}
    else:
        provenance = {"extra": {"legacy_id": legacy_id}}

    payload = {**raw, "id": target_id, "generation_metadata": provenance}
    payload.setdefault("language", "en")
    payload.setdefault("pack_id", None)
    # Pre-set embedding columns; actual vector filled in below if missing.
    payload.setdefault("embedding_model", EMBEDDING_MODEL)
    payload.setdefault("embedding_dim", EMBEDDING_DIM)
    return Question.model_validate(payload)


def _batched(items: Sequence, size: int) -> Iterable[Sequence]:
    for i in range(0, len(items), size):
        yield items[i:i + size]


def _embed_batch(client: OpenAI, texts: List[str]) -> List[List[float]]:
    response = client.embeddings.create(model=EMBEDDING_MODEL, input=texts)
    return [d.embedding for d in response.data]


async def _existing_ids(session: AsyncSession, ids: Sequence[str]) -> set[str]:
    if not ids:
        return set()
    uuids = [uuid.UUID(i) for i in ids]
    result = await session.execute(
        select(QuestionRow.id).where(QuestionRow.id.in_(uuids))
    )
    return {str(row[0]) for row in result.all()}


def _row_to_insert_dict(row: QuestionRow) -> dict:
    """Plain ``{column_name: value}`` dict for a dialect-level INSERT."""
    return {c.name: getattr(row, c.name) for c in QuestionRow.__table__.columns}


async def _run(args: argparse.Namespace) -> int:
    if args.sqlite_path:
        paths = [Path(p) for p in args.sqlite_path]
    else:
        paths = [p for p in DEFAULT_SQLITE_PATHS if p.exists()]
    paths = [p for p in paths if p.exists()]
    if not paths:
        logger.error(
            "No SQLite pending.db files found. Pass --sqlite-path or place a "
            "pending.db at one of: %s",
            ", ".join(str(p) for p in DEFAULT_SQLITE_PATHS),
        )
        return 1

    per_source_counts: dict[str, int] = {}
    by_legacy: dict[str, dict] = {}
    for path in paths:
        count = 0
        for legacy_id, raw in _load_pending_rows(path):
            count += 1
            by_legacy.setdefault(legacy_id, raw)
        per_source_counts[str(path)] = count
        logger.info("Read %d row(s) from %s", count, path)

    questions = [_build_question(lid, raw) for lid, raw in by_legacy.items()]
    logger.info("Deduped across sources: %d unique question(s)", len(questions))

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

        to_insert = [q for q in questions if q.id not in existing]
        needs_embedding = [q for q in to_insert if q.embedding is None]
        batches = (len(needs_embedding) + args.batch_size - 1) // args.batch_size

        print("── source counts ────────────────────────────────")
        for path, count in per_source_counts.items():
            print(f"  {path}: {count} row(s)")
        print(f"Unique after dedupe:       {len(questions)}")
        print(f"Already present in PG:     {len(existing)}")
        print(f"Would insert:              {len(to_insert)}")
        print(f"Need embedding:            {len(needs_embedding)} "
              f"({batches} OpenAI batch call(s) of {args.batch_size})")

        if args.dry_run or not args.execute:
            return 0

        if needs_embedding:
            if not os.getenv("OPENAI_API_KEY"):
                logger.error("OPENAI_API_KEY not set; cannot embed %d row(s).",
                             len(needs_embedding))
                return 2
            client = OpenAI()
            for i, batch in enumerate(_batched(needs_embedding, args.batch_size), 1):
                vectors = _embed_batch(client, [q.question for q in batch])
                for q, vec in zip(batch, vectors):
                    q.embedding = list(vec)
                    q.embedding_model = EMBEDDING_MODEL
                    q.embedding_dim = EMBEDDING_DIM
                logger.info("Embedded batch %d/%d (%d row(s))", i, batches, len(batch))

        rows = [_row_to_insert_dict(question_to_row(q)) for q in to_insert]
        inserted = 0
        if rows:
            async with async_engine.begin() as conn:
                stmt = (
                    pg_insert(QuestionRow.__table__)
                    .values(rows)
                    .on_conflict_do_nothing(index_elements=["id"])
                )
                result = await conn.execute(stmt)
                inserted = result.rowcount or 0

        print("── result ───────────────────────────────────────")
        print(f"Inserted: {inserted}")
        print(f"Skipped (already present): {len(existing)}")
        return 0
    finally:
        if owned_engine:
            await async_engine.dispose()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    parser = argparse.ArgumentParser(
        description="Migrate SQLite pending.db rows into Postgres `questions`.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--sqlite-path", action="append", default=[],
        help="Path to a SQLite pending.db. Repeatable. "
             "Defaults search apps/quiz-pack-api/{,data/}pending.db and ./pending.db.",
    )
    parser.add_argument(
        "--database-url",
        help="Postgres URL (libpq or asyncpg form). Defaults to app.config.Settings.",
    )
    parser.add_argument(
        "--batch-size", type=int, default=100,
        help="OpenAI embedding batch size (default 100, per Task 1.6 spec).",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true",
                      help="Print counts; perform no writes (default).")
    mode.add_argument("--execute", action="store_true",
                      help="Perform inserts.")
    args = parser.parse_args()
    if not args.dry_run and not args.execute:
        args.dry_run = True
    return asyncio.run(_run(args))


if __name__ == "__main__":
    sys.exit(main())
