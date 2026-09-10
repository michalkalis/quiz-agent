#!/usr/bin/env python3
"""JSON question batch → Postgres ``questions`` importer (#72 corpus swap).

Reads one or more JSON files each holding a list of Pydantic ``Question``
dicts (the persist-free harness output, e.g. ``data/generation-2026-07-10/
batch.json``), stamps the requested review_status, embeds rows that lack a
vector (OpenAI ``text-embedding-3-small``, batched), and inserts idempotently
on the primary key. Same seam and runbook shape as
``migrate_pending_to_postgres.py``.

Review status is decided **per row** by default (``--review-status auto``,
#177): an English shared-corpus row that cleared every machine gate with zero
findings lands as ``approved`` (stamped ``reviewed_by="machine:gates-v1"``) and
serves to every client; anything with a finding — or any missing evidence, the
predicate is fail-closed — lands as ``pending_review`` (TestFlight-only
serving). Founder decision 2026-09-10 replaced the 2026-08-28 rule that only a
human could produce ``approved``; see ``app.scoring.machine_approval``. An
explicit ``--review-status`` still forces EVERY row to that status (the human
promotion / quarantine path).

Usage
-----
::

    # Local dry-run (uses DATABASE_URL from .env), per-row auto status
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
from datetime import datetime, timezone
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
from app.scoring.machine_approval import (  # noqa: E402
    GATE_VERSION,
    machine_approval_block_reason,
    tf_imbalance_excess_ids,
)
from quiz_shared.models.question import Question  # noqa: E402
from quiz_shared.utils.qa_text import qa_text  # noqa: E402
from scripts.migrate_pending_to_postgres import (  # noqa: E402
    EMBEDDING_DIM,
    EMBEDDING_MODEL,
    _batched,
    _embed_batch,
    _existing_ids,
    _row_to_insert_dict,
)

logger = logging.getLogger("import_questions_json")

# `--review-status auto` (the default, #177): decide per row via the machine
# approval predicate instead of stamping one status on the whole batch.
AUTO_REVIEW_STATUS = "auto"


def _verification_block_reason(q: Question) -> str | None:
    """#158 fail-closed corpus guard: why this row must NOT be imported.

    A pipeline row the verifier held (`held_for_review`) or explicitly failed
    (`verified: False`) never enters the corpus, under any `--review-status`.
    Rows without verification keys (hand-curated content that never ran the
    pipeline) are not blocked — the guard targets pipeline provenance.
    """
    extra = q.generation_metadata.extra if q.generation_metadata else {}
    if extra.get("held_for_review"):
        return "held_for_review"
    if extra.get("verified") is False:
        return "verified=False"
    return None


def _apply_auto_review_status(questions: List[Question]) -> dict[str, int]:
    """Stamp ``approved`` / ``pending_review`` per row (#177); return reasons.

    ``approved`` here means "every machine gate cleared with zero findings",
    marked ``reviewed_by=machine:gates-v1`` so it stays distinguishable from a
    human verdict (`reviewed_by LIKE 'machine:%'`). The returned Counter-shaped
    dict maps block reason → row count, so a dry run shows WHY rows stayed
    pending instead of only how many.
    """
    tf_excess = tf_imbalance_excess_ids(questions)
    now = datetime.now(timezone.utc)
    reasons: dict[str, int] = {}
    for q in questions:
        reason = machine_approval_block_reason(q, tf_excess)
        if reason is None:
            q.review_status = "approved"
            q.reviewed_by = GATE_VERSION
            q.reviewed_at = now
            continue
        q.review_status = "pending_review"
        reasons[reason] = reasons.get(reason, 0) + 1
    return reasons


def _load_questions(
    paths: List[Path], review_status: str, stats: dict | None = None
) -> List[Question]:
    """Parse the batches, drop #158-blocked rows, stamp the review status.

    ``review_status="auto"`` defers to `_apply_auto_review_status`; an explicit
    status is forced onto every surviving row. The #158 verification guard runs
    FIRST either way — a held/failed row never enters the corpus, so it never
    reaches the approval predicate at all.
    """
    by_id: dict[str, Question] = {}
    rejected = 0
    for path in paths:
        raw_list = json.loads(path.read_text())
        for raw in raw_list:
            row_status = (
                "pending_review" if review_status == AUTO_REVIEW_STATUS else review_status
            )
            payload = {**raw, "review_status": row_status}
            payload.setdefault("embedding_model", EMBEDDING_MODEL)
            payload.setdefault("embedding_dim", EMBEDDING_DIM)
            q = Question.model_validate(payload)
            reason = _verification_block_reason(q)
            if reason is not None:
                rejected += 1
                logger.error(
                    "REJECTED (fail-closed, #158): id=%s %s — unverified/held "
                    "questions never enter the corpus. Question: %.80s",
                    q.id,
                    reason,
                    q.question,
                )
                continue
            by_id.setdefault(q.id, q)
        logger.info("Read %d row(s) from %s", len(raw_list), path)
    if rejected:
        print(f"REJECTED unverified/held rows: {rejected} (see log above)")
    questions = list(by_id.values())
    if review_status == AUTO_REVIEW_STATUS:
        block_reasons = _apply_auto_review_status(questions)
        if stats is not None:
            stats["block_reasons"] = block_reasons
    return questions


async def _run(args: argparse.Namespace) -> int:
    paths = [Path(p) for p in args.json_path]
    missing = [p for p in paths if not p.exists()]
    if missing:
        logger.error("JSON file(s) not found: %s", ", ".join(str(p) for p in missing))
        return 1

    stats: dict = {}
    questions = _load_questions(paths, args.review_status, stats)

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
        # #170 D2/D10: every imported row carries BOTH vectors — the question
        # embedding (retrieval + question-only dedup) and the question+answer
        # embedding (`embedding_qa`, the QA dedup branch) — so the corpus never
        # needs a paid backfill for rows that went through this importer.
        needs_embedding = [
            q for q in to_insert if q.embedding is None or q.embedding_qa is None
        ]
        batches = (len(needs_embedding) + args.batch_size - 1) // args.batch_size

        print(f"Unique across files:       {len(questions)}")
        print(f"Already present in PG:     {len(existing)}")
        print(f"Would insert:              {len(to_insert)} "
              f"(review_status={args.review_status!r})")
        _print_review_status_split(to_insert, stats)
        print(f"Need embedding:            {len(needs_embedding)} "
              f"({batches} OpenAI batch call(s) of {args.batch_size}, "
              f"question + question/answer text per row)")

        if args.dry_run or not args.execute:
            return 0

        if needs_embedding:
            if not os.getenv("OPENAI_API_KEY"):
                logger.error("OPENAI_API_KEY not set; cannot embed %d row(s).",
                             len(needs_embedding))
                return 2
            client = OpenAI()
            for i, batch in enumerate(_batched(needs_embedding, args.batch_size), 1):
                # One OpenAI call per batch: question texts first, then the
                # matching question+answer texts (same order, same model).
                vectors = _embed_batch(
                    client,
                    [q.question for q in batch]
                    + [qa_text(q.question, q.correct_answer, q.possible_answers) for q in batch],
                )
                q_vectors, qa_vectors = vectors[: len(batch)], vectors[len(batch):]
                for q, vec, qa_vec in zip(batch, q_vectors, qa_vectors):
                    if q.embedding is None:
                        q.embedding = list(vec)
                        q.embedding_model = EMBEDDING_MODEL
                        q.embedding_dim = EMBEDDING_DIM
                    if q.embedding_qa is None:
                        q.embedding_qa = list(qa_vec)
                        q.embedding_qa_model = EMBEDDING_MODEL
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


def _print_review_status_split(questions: List[Question], stats: dict) -> None:
    """Show the approved/pending split and the top reasons rows stayed pending.

    A silent count would hide a systematic miss (e.g. a whole batch blocked on
    one missing field) behind "0 approved" — the reasons make it legible
    before `--execute`.
    """
    approved = sum(1 for q in questions if q.review_status == "approved")
    pending = len(questions) - approved
    print(f"  machine-approved:        {approved} (reviewed_by={GATE_VERSION!r})")
    print(f"  pending_review:          {pending}")
    reasons = stats.get("block_reasons") or {}
    top = sorted(reasons.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
    for reason, count in top:
        print(f"    {count:>5}  {reason}")


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
    parser.add_argument("--review-status", default=AUTO_REVIEW_STATUS,
                        choices=(AUTO_REVIEW_STATUS, *REVIEW_STATUSES),
                        help="review_status for imported rows. Default 'auto' (#177): decided per "
                             "row by the machine-approval predicate — clean EN rows become "
                             "'approved' (reviewed_by=machine:gates-v1), the rest "
                             "'pending_review'. An explicit value forces every row.")
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
