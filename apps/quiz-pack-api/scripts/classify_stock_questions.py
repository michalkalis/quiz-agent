#!/usr/bin/env python3
"""Run the #203 stock-question check over the approved corpus (read-only).

Reads every ``approved`` question (minus ``--exclude-category``), asks
``StockQuestionChecker`` in batches, and writes one JSON record per question
(id, category, language, text, answer, options, stock, reason) to ``--out``.
Nothing in the database changes; archiving is a separate, founder-approved step.

Usage (from ``apps/quiz-pack-api/``, prod via ``fly proxy 15432:5432 -a quiz-pack-db``)::

    python scripts/classify_stock_questions.py \\
        --database-url "$PROD_DATABASE_URL" --exclude-category entertainment \\
        --out ../../docs/testing/runs/stock-questions-2026-10-14/verdicts.json
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.image_generation.env_loader import load_env  # noqa: E402

load_env()

from sqlalchemy import select  # noqa: E402
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine  # noqa: E402

from app.db import QuestionRow, engine, normalize_async_url, row_to_question  # noqa: E402
from app.verification.stock_question import StockQuestionChecker  # noqa: E402

BATCH_SIZE = 20
MAX_CONCURRENT_BATCHES = 4


async def _load(database_url: str | None, exclude: list[str]):
    async_engine = (
        create_async_engine(normalize_async_url(database_url), future=True)
        if database_url
        else engine
    )
    try:
        where = QuestionRow.review_status == "approved"
        if exclude:
            where = where & QuestionRow.category.notin_(exclude)
        async with AsyncSession(async_engine) as session:
            rows = (
                await session.execute(select(QuestionRow).where(where).order_by(QuestionRow.id))
            ).scalars().all()
            return [row_to_question(r) for r in rows]
    finally:
        if database_url:
            await async_engine.dispose()


async def _run(args: argparse.Namespace) -> int:
    questions = await _load(args.database_url, args.exclude_category)
    print(f"Approved questions to check: {len(questions)}")
    checker = StockQuestionChecker()
    semaphore = asyncio.Semaphore(MAX_CONCURRENT_BATCHES)
    batches = [questions[i : i + BATCH_SIZE] for i in range(0, len(questions), BATCH_SIZE)]

    async def run(batch):
        async with semaphore:
            return await checker.check(batch)

    verdicts = [v for vs in await asyncio.gather(*(run(b) for b in batches)) for v in vs]
    records = [
        {
            "id": q.id,
            "category": q.category,
            "language": q.language,
            "question": q.question,
            "answer": q.correct_answer,
            "options": list(q.possible_answers.values()) if q.possible_answers else None,
            "stock": v.stock if v else None,
            "reason": v.reason if v else None,
        }
        for q, v in zip(questions, verdicts)
    ]
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(records, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")

    by_cat: dict[str, Counter] = {}
    for r in records:
        by_cat.setdefault(r["category"], Counter())[str(r["stock"])] += 1
    print("category            stock / total   (no verdict)")
    for cat, c in sorted(by_cat.items()):
        total = sum(c.values())
        print(f"{cat:<20}{c['True']:>5} / {total:<6}  ({c['None']})")
    unchecked = sum(c["None"] for c in by_cat.values())
    print(f"Wrote {len(records)} records to {out}; {unchecked} without a verdict")
    return 1 if unchecked == len(records) else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--database-url", help="Postgres URL (default: app settings).")
    parser.add_argument("--exclude-category", action="append", default=[],
                        help="Category to skip. Repeatable.")
    parser.add_argument("--out", required=True, help="Output JSON path.")
    return asyncio.run(_run(parser.parse_args()))


if __name__ == "__main__":
    sys.exit(main())
