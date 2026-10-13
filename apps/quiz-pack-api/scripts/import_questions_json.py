#!/usr/bin/env python3
"""JSON question batch → Postgres ``questions`` importer (#72 corpus swap).

Reads one or more JSON files each holding a list of Pydantic ``Question``
dicts (the persist-free harness output, e.g. ``data/generation-2026-07-10/
batch.json``), stamps the requested review_status, embeds rows that lack a
vector (OpenAI ``text-embedding-3-small``, batched), and inserts idempotently
on the primary key. Same seam and runbook shape as
``migrate_pending_to_postgres.py``.

Review status is decided **per row** by default (``--review-status auto``,
#177): a shared-corpus row (en, sk or cs, see
``app.scoring.machine_approval.MACHINE_APPROVABLE_LANGUAGES``) that cleared
every machine gate with zero findings lands as ``approved`` (stamped
``reviewed_by="machine:gates-v1"``) and serves to every client; anything with a
finding — or any missing evidence, the predicate is fail-closed — lands as
``pending_review`` (TestFlight-only serving). Founder decision 2026-09-10
replaced the 2026-08-28 rule that only a human could produce ``approved``; see
``app.scoring.machine_approval``. An explicit ``--review-status`` still forces
EVERY row to that status (the human promotion / quarantine path).

The core (guard, status decision, embedding, insert) lives in
``app.corpus.importer`` (#202); this file is the CLI wrapper.

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
import logging
import sys
from pathlib import Path
from typing import List

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.image_generation.env_loader import load_env  # noqa: E402

load_env()

from app.corpus.importer import (  # noqa: E402
    AUTO_REVIEW_STATUS,
    EmbeddingKeyMissing,
    ImportResult,
    import_questions,
    parse_question_files,
    prepare_questions,
)
from app.db.models.question import REVIEW_STATUSES  # noqa: E402
from app.scoring.machine_approval import GATE_VERSION  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402

logger = logging.getLogger("import_questions_json")


def _load_questions(
    paths: List[Path], review_status: str, stats: dict | None = None
) -> List[Question]:
    """Parse the batches, drop #158-blocked rows, stamp the review status."""
    return prepare_questions(
        parse_question_files(paths, review_status), review_status, stats
    )


def _print_plan(result: ImportResult, args: argparse.Namespace) -> None:
    if result.skipped:
        print(f"REJECTED unverified/held rows: {len(result.skipped)} (see log above)")
    batches = (result.needs_embedding + args.batch_size - 1) // args.batch_size
    print(f"Unique across files:       {result.unique}")
    print(f"Already present in PG:     {result.already_present}")
    print(f"Would insert:              {result.to_insert} "
          f"(review_status={args.review_status!r})")
    if args.review_status == AUTO_REVIEW_STATUS:
        # Only auto mode produces a split (and machine markers) — printing
        # it for a forced status would claim `reviewed_by=machine:…` on
        # rows that will be inserted with NULL.
        _print_review_status_split(result)
    print(f"Need embedding:            {result.needs_embedding} "
          f"({batches} OpenAI batch call(s) of {args.batch_size}, "
          f"question + question/answer text per row)")


async def _run(args: argparse.Namespace) -> int:
    paths = [Path(p) for p in args.json_path]
    missing = [p for p in paths if not p.exists()]
    if missing:
        logger.error("JSON file(s) not found: %s", ", ".join(str(p) for p in missing))
        return 1

    questions = parse_question_files(paths, args.review_status)
    execute = not (args.dry_run or not args.execute)
    try:
        result = await import_questions(
            questions,
            database_url_or_engine=args.database_url or None,
            review_status=args.review_status,
            execute=execute,
            batch_size=args.batch_size,
            on_plan=lambda r: _print_plan(r, args),
        )
    except EmbeddingKeyMissing as exc:
        logger.error("%s", exc)
        return 2
    if execute:
        print(f"Inserted: {result.inserted}")
    return 0


def _print_review_status_split(result: ImportResult) -> None:
    """Show the approved/pending split and the top reasons rows stayed pending.

    A silent count would hide a systematic miss (e.g. a whole batch blocked on
    one missing field) behind "0 approved" — the reasons make it legible
    before `--execute`.
    """
    print(f"  machine-approved:        {result.approved} (reviewed_by={GATE_VERSION!r})")
    print(f"  pending_review:          {result.pending}")
    top = sorted(result.block_reasons.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
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
                             "row by the machine-approval predicate — clean en/sk/cs rows become "
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
