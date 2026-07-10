#!/usr/bin/env python3
"""Archive the pre-#72 corpus: approved → 'archived' (#72 corpus swap).

Flips ``review_status`` to ``'archived'`` on every ``approved`` question whose
id is NOT listed in the given keep-files (JSON lists of Question dicts — the
new-pipeline batches). Nothing is deleted; restoring is a single UPDATE back
to ``'approved'``. Requires migration ``7a2c91d40b1e`` (adds 'archived' to the
check constraint).

Usage
-----
::

    # Dry-run against prod (via `fly proxy`)
    python scripts/archive_questions.py \\
        --keep-json data/generation-2026-07-10/batch.json \\
        --keep-json data/validation-2026-07-10/fresh_batch.json \\
        --database-url "$PROD_DATABASE_URL"

    # Then rerun with --execute.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.image_generation.env_loader import load_env  # noqa: E402

load_env()

from sqlalchemy import func, select, update  # noqa: E402
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine  # noqa: E402

from app.db import QuestionRow, engine, normalize_async_url  # noqa: E402

logger = logging.getLogger("archive_questions")

ARCHIVE_NOTE = "archived 2026-07-10 — pre-#72 corpus retired by founder decision"


def _keep_ids(paths: list[Path]) -> set[uuid.UUID]:
    ids: set[uuid.UUID] = set()
    for path in paths:
        for raw in json.loads(path.read_text()):
            ids.add(uuid.UUID(raw["id"]))
        logger.info("Keep-list %s loaded", path)
    return ids


async def _run(args: argparse.Namespace) -> int:
    paths = [Path(p) for p in args.keep_json]
    missing = [p for p in paths if not p.exists()]
    if missing:
        logger.error("Keep file(s) not found: %s", ", ".join(str(p) for p in missing))
        return 1
    keep = _keep_ids(paths)

    if args.database_url:
        async_engine = create_async_engine(
            normalize_async_url(args.database_url), future=True
        )
        owned_engine = True
    else:
        async_engine = engine
        owned_engine = False

    target = (QuestionRow.review_status == "approved") & (
        QuestionRow.id.notin_(keep) if keep else True
    )
    try:
        async with AsyncSession(async_engine, expire_on_commit=False) as session:
            approved = (
                await session.execute(
                    select(func.count()).select_from(QuestionRow).where(
                        QuestionRow.review_status == "approved"
                    )
                )
            ).scalar_one()
            to_archive = (
                await session.execute(
                    select(func.count()).select_from(QuestionRow).where(target)
                )
            ).scalar_one()

        print(f"Keep-list ids:             {len(keep)}")
        print(f"Approved now:              {approved}")
        print(f"Would archive:             {to_archive}")
        print(f"Approved after:            {approved - to_archive}")

        if args.dry_run or not args.execute:
            return 0

        async with async_engine.begin() as conn:
            result = await conn.execute(
                update(QuestionRow.__table__)
                .where(target)
                .values(
                    review_status="archived",
                    review_notes=ARCHIVE_NOTE,
                    reviewed_at=datetime.now(timezone.utc),
                )
            )
        print(f"Archived: {result.rowcount}")
        return 0
    finally:
        if owned_engine:
            await async_engine.dispose()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    parser = argparse.ArgumentParser(
        description="Archive approved questions not present in the keep-lists.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--keep-json", action="append", required=True,
                        help="JSON list of Question dicts whose ids stay approved. Repeatable.")
    parser.add_argument("--database-url",
                        help="Postgres URL. Defaults to app.config.Settings.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true",
                      help="Print counts; perform no writes (default).")
    mode.add_argument("--execute", action="store_true", help="Perform the update.")
    args = parser.parse_args()
    if not args.dry_run and not args.execute:
        args.dry_run = True
    return asyncio.run(_run(args))


if __name__ == "__main__":
    sys.exit(main())
