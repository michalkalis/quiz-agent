#!/usr/bin/env python3
"""Backfill every historical founder-rating round into the #154 store (#156).

Writes through `app.api.v1.ratings_store.upsert_rating` — the same upsert
contract the web page and the in-app panel use — so a re-run converges on the
source files instead of duplicating them. The natural key per round comes from
the source file itself (see `backfill_ratings_parsers`), which is what makes
"run it again" a no-op.

Raw scores are stored exactly as the founder gave them, with the round's own
scale bounds; the 1–5 rounds are reconciled with the 1–10 ones only in the
export's derived column.

Usage
-----
::

    # Counts only, no writes (default)
    python scripts/backfill_ratings.py

    # Write, one round at a time
    python scripts/backfill_ratings.py --execute --only pilot-2026-07-11

    # Against an explicit database (e.g. the local test DB)
    python scripts/backfill_ratings.py --execute --database-url "$TEST_DATABASE_URL"

The prod run is founder-gated: it writes rows into the live ratings store.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.image_generation.env_loader import load_env  # noqa: E402

load_env()

from sqlalchemy import select  # noqa: E402
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine  # noqa: E402

from app.api.v1.ratings_store import upsert_rating  # noqa: E402
from app.db import engine, normalize_async_url  # noqa: E402
from app.db.models.rating import Rating  # noqa: E402
from scripts import backfill_ratings_parsers as P  # noqa: E402

# The one round that cannot be backfilled: the 36 per-question scores behind
# the July rubric lived in an uncommitted scratchpad. Only the aggregate
# conclusions survive, in the calibration doc. No synthetic rows are written —
# an invented score would silently become "founder ground truth" downstream.
JULY_NOTE = (
    "july-calibration 2026-07-09 (36 ratings, 1–5): RAW DATA LOST — scratchpad "
    "never committed; only the rubric conclusions survive in "
    "docs/research/question-quality-founder-calibration-2026-07-09.md. "
    "Zero rows written by design."
)


def collect(root: Path, only: list[str] | None) -> list[P.SourceResult]:
    """Parse every source (or just the named rounds). Raises on a bad format."""
    pilot = root / "apps/quiz-pack-api/data/pilot-2026-07-11"
    baseline = root / "docs/testing/runs/153-baseline-2026-08-07"
    phase_a = root / "docs/testing/runs/153-phase-a"
    sources = [
        lambda: P.parse_gold_library(root / "data/examples/gold_standard.json"),
        lambda: P.parse_pilot(
            pilot / "founder_ratings.md", pilot / "pilot_review.md"
        ),
        lambda: P.parse_g3_sample(
            root / "docs/testing/runs/corpus-blind-sample-2026-07.md"
        ),
        lambda: P.parse_baseline(
            baseline / "founder-ratings.json",
            baseline / "questions-with-judge-scores.json",
        ),
        lambda: P.parse_phase_a(
            phase_a / "founder-ratings-full.json", phase_a / "mapping.json"
        ),
    ]
    results = [fn() for fn in sources]
    if only:
        unknown = set(only) - {r.round for r in results}
        if unknown:
            raise SystemExit(f"Unknown round(s): {', '.join(sorted(unknown))}")
        results = [r for r in results if r.round in only]
    return results


async def _existing_keys(session: AsyncSession, keys: list[str]) -> set[str]:
    if not keys:
        return set()
    rows = await session.execute(
        select(Rating.dedupe_key).where(Rating.dedupe_key.in_(keys))
    )
    return set(rows.scalars())


async def _apply(
    session: AsyncSession, result: P.SourceResult, execute: bool
) -> tuple[int, int]:
    """Return (new, updated) for this round; write only when `execute`."""
    known = await _existing_keys(session, [r.dedupe_key for r in result.rows])
    new = sum(1 for r in result.rows if r.dedupe_key not in known)
    updated = len(result.rows) - new
    if not execute:
        return new, updated
    for row in result.rows:
        await upsert_rating(
            session,
            dedupe_key=row.dedupe_key,
            question_text=row.question_text,
            rater=row.rater,
            score=row.score,
            source=row.source,
            reason=row.reason,
            question_id=row.question_id,
            blinded_qid=row.blinded_qid,
            extra=row.extra,
            scale_min=row.scale_min,
            scale_max=row.scale_max,
            rated_at=row.rated_at,
            refresh_identity=True,
        )
    return new, updated


async def _run(args: argparse.Namespace) -> int:
    results = collect(P.REPO_ROOT, args.only)

    if args.database_url:
        eng = create_async_engine(normalize_async_url(args.database_url), future=True)
        owned = True
    else:
        eng = engine
        owned = False

    mode = "EXECUTE" if args.execute else "DRY-RUN"
    header = f"{'round':<28}{'seen':>6}{'new':>6}{'upd':>6}{'skip':>6}{'unjoin':>8}"
    print(f"\n#156 ratings backfill — {mode}")
    print(header)
    print("-" * len(header))
    totals = [0, 0, 0, 0, 0]
    anomalies: list[str] = []
    try:
        async with AsyncSession(eng, expire_on_commit=False) as session:
            for result in results:
                new, updated = await _apply(session, result, args.execute)
                counts = [result.seen, new, updated, result.skipped, result.unjoinable]
                totals = [t + c for t, c in zip(totals, counts)]
                print(
                    f"{result.round:<28}{counts[0]:>6}{counts[1]:>6}"
                    f"{counts[2]:>6}{counts[3]:>6}{counts[4]:>8}"
                )
                anomalies += [f"{result.round}: {a}" for a in result.anomalies]
    finally:
        if owned:
            await eng.dispose()

    print("-" * len(header))
    print(
        f"{'TOTAL':<28}{totals[0]:>6}{totals[1]:>6}"
        f"{totals[2]:>6}{totals[3]:>6}{totals[4]:>8}"
    )
    print(f"\nlost round: {JULY_NOTE}")
    if anomalies:
        print("\nanomalies (founder attention):")
        for line in anomalies:
            print(f"  - {line}")
    if not args.execute:
        print("\nNo writes performed. Re-run with --execute.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Import historical founder ratings into the #154 store.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--only", action="append",
        help="Round label to import (repeatable). Default: all rounds.",
    )
    parser.add_argument(
        "--database-url", help="Postgres URL. Defaults to app.config.Settings."
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--dry-run", action="store_true", help="Print counts, write nothing (default)."
    )
    mode.add_argument("--execute", action="store_true", help="Perform the upserts.")
    args = parser.parse_args()
    return asyncio.run(_run(args))


if __name__ == "__main__":
    sys.exit(main())
