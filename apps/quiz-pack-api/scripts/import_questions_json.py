#!/usr/bin/env python3
"""JSON question batch → Postgres ``questions`` importer (#72 corpus swap).

Reads one or more JSON files each holding a list of Pydantic ``Question``
dicts (the persist-free harness output, e.g. ``data/generation-2026-07-10/
batch.json``), stamps the requested review_status, embeds rows that lack a
vector (OpenAI ``text-embedding-3-small``, batched), and inserts idempotently
on the primary key. Same seam and runbook shape as
``migrate_pending_to_postgres.py``.

Usage
-----
::

    # Local dry-run (uses DATABASE_URL from .env)
    python scripts/import_questions_json.py --json-path data/generation-2026-07-10/batch.json

    # Prod execute against the Fly Postgres instance (via `fly proxy`)
    python scripts/import_questions_json.py \\
        --json-path data/generation-2026-07-10/batch.json \\
        --database-url "$PROD_DATABASE_URL" --execute
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
from pathlib import Path
from typing import List

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.image_generation.env_loader import load_env  # noqa: E402

load_env()

from openai import OpenAI  # noqa: E402
from sqlalchemy.dialects.postgresql import insert as pg_insert  # noqa: E402
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine  # noqa: E402

from app.db import QuestionRow, engine, normalize_async_url, question_to_row  # noqa: E402
from app.db.models.question import REVIEW_STATUSES  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402
from scripts.migrate_pending_to_postgres import (  # noqa: E402
    EMBEDDING_DIM,
    EMBEDDING_MODEL,
    _batched,
    _embed_batch,
    _existing_ids,
    _row_to_insert_dict,
)

logger = logging.getLogger("import_questions_json")


def _load_questions(paths: List[Path], review_status: str) -> List[Question]:
    by_id: dict[str, Question] = {}
    for path in paths:
        raw_list = json.loads(path.read_text())
        for raw in raw_list:
            payload = {**raw, "review_status": review_status}
            payload.setdefault("embedding_model", EMBEDDING_MODEL)
            payload.setdefault("embedding_dim", EMBEDDING_DIM)
            q = Question.model_validate(payload)
            by_id.setdefault(q.id, q)
        logger.info("Read %d row(s) from %s", len(raw_list), path)
    return list(by_id.values())


async def _run(args: argparse.Namespace) -> int:
    paths = [Path(p) for p in args.json_path]
    missing = [p for p in paths if not p.exists()]
    if missing:
        logger.error("JSON file(s) not found: %s", ", ".join(str(p) for p in missing))
        return 1

    questions = _load_questions(paths, args.review_status)

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

        print(f"Unique across files:       {len(questions)}")
        print(f"Already present in PG:     {len(existing)}")
        print(f"Would insert:              {len(to_insert)} "
              f"(review_status={args.review_status!r})")
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

        print(f"Inserted: {inserted}")
        return 0
    finally:
        if owned_engine:
            await async_engine.dispose()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    parser = argparse.ArgumentParser(
        description="Import JSON question batches into Postgres `questions`.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--json-path", action="append", required=True,
                        help="Path to a JSON list of Question dicts. Repeatable.")
    parser.add_argument("--database-url",
                        help="Postgres URL. Defaults to app.config.Settings.")
    parser.add_argument("--review-status", default="approved", choices=REVIEW_STATUSES,
                        help="review_status stamped on every imported row (default: approved).")
    parser.add_argument("--batch-size", type=int, default=100,
                        help="OpenAI embedding batch size (default 100).")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true",
                      help="Print counts; perform no writes (default).")
    mode.add_argument("--execute", action="store_true", help="Perform inserts.")
    args = parser.parse_args()
    if not args.dry_run and not args.execute:
        args.dry_run = True
    return asyncio.run(_run(args))


if __name__ == "__main__":
    sys.exit(main())
