#!/usr/bin/env python3
"""#211 backfill: naturalness label for native sk/cs corpus rows.

Selects live sk/cs corpus rows (``pack_id IS NULL``, approved or pending
review; customer packs are private and out of scope) without a verdict yet
(no ``provenance.extra.naturalness``), runs
``app.generation.naturalness_check`` in batches and writes the verdict (with
its proposed rewrite) into ``provenance``. The question text is never changed
here: rewrites are applied only after the founder's blind pairs approve them
(#211 211.4). Resumable: an unchecked row is picked up by the next run.

Modes::

    cd apps/quiz-pack-api
    # sample: 20 sk + 20 cs random unchecked rows, nothing written
    DATABASE_URL=... python scripts/check_naturalness.py --sample --out s.json
    # full run (dry by default; --execute writes)
    DATABASE_URL=... python scripts/check_naturalness.py --execute
    # re-check given rows with the current prompt (replaces their verdict)
    DATABASE_URL=... python scripts/check_naturalness.py --ids ids.json --execute
    # swap in the stored rewrite of given rows, re-embed (founder-approved)
    DATABASE_URL=... python scripts/check_naturalness.py --apply ids.json \
        --applied-by founder-pairs-2026-10-23 --execute

Prints one ``lang | verdict | problems | question`` line per row, a
per-language count of flagged rows, and the token cost of the run.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
from collections import Counter
from collections.abc import Sequence

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_APP_DIR = os.path.dirname(_SCRIPT_DIR)
if _APP_DIR in sys.path:
    sys.path.remove(_APP_DIR)
sys.path.insert(0, _APP_DIR)

from app import llm_usage  # noqa: E402
from app.corpus.importer import _embed_questions  # noqa: E402
from app.db.engine import normalize_async_url  # noqa: E402
from app.db.models import QuestionRow, row_to_question  # noqa: E402
from app.generation.naturalness_check import (  # noqa: E402
    DEFAULT_BATCH_SIZE,
    LANGUAGES,
    NaturalnessChecker,
    apply_rewrite,
)
from quiz_shared.llm import factory as llm_factory  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402
from sqlalchemy import and_, func, or_, select, update  # noqa: E402
from sqlalchemy.ext.asyncio import (  # noqa: E402
    AsyncEngine,
    AsyncSession,
    create_async_engine,
)

logger = logging.getLogger("check_naturalness")

SAMPLE_PER_LANGUAGE = {"sk": 20, "cs": 20}


def _unlabelled_clause():
    """Live sk/cs corpus rows without a naturalness verdict."""
    return and_(
        QuestionRow.pack_id.is_(None),
        QuestionRow.language.in_(LANGUAGES),
        QuestionRow.review_status.in_(("approved", "pending_review")),
        or_(
            QuestionRow.provenance.is_(None),
            ~QuestionRow.provenance["extra"].has_key("naturalness"),
        ),
    )


def _corpus_clause():
    return and_(
        QuestionRow.pack_id.is_(None),
        QuestionRow.language.in_(LANGUAGES),
    )


async def load_ids(engine: AsyncEngine, ids: Sequence[str]) -> list[Question]:
    """Corpus sk/cs rows by id, whatever their verdict."""
    async with AsyncSession(engine) as session:
        stmt = select(QuestionRow).where(_corpus_clause(), QuestionRow.id.in_(ids))
        rows = list((await session.scalars(stmt)).all())
    if len(rows) != len(set(ids)):
        print(f"WARNING: {len(set(ids)) - len(rows)} id(s) not found as sk/cs corpus rows")
    return [row_to_question(row) for row in rows]


async def write_rewrites(engine: AsyncEngine, questions: Sequence[Question]) -> int:
    """Persist question text, both vectors and provenance of swapped rows."""
    async with engine.begin() as conn:
        for q in questions:
            await conn.execute(
                update(QuestionRow)
                .where(QuestionRow.id == q.id)
                .values(
                    question=q.question,
                    embedding=q.embedding,
                    embedding_model=q.embedding_model,
                    embedding_dim=q.embedding_dim,
                    embedding_qa=q.embedding_qa,
                    embedding_qa_model=q.embedding_qa_model,
                    provenance=q.generation_metadata.model_dump(mode="json"),
                )
            )
    return len(questions)


def read_ids(path: str) -> list[str]:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


async def run_apply(engine: AsyncEngine, args: argparse.Namespace) -> int:
    questions = await load_ids(engine, read_ids(args.apply))
    swapped = [q for q in questions if apply_rewrite(q, args.applied_by)]
    for q in swapped:
        verdict = q.generation_metadata.extra["naturalness"]
        print(f"{q.language} | - {verdict['original_question']}\n   | + {q.question}")
    print(f"{len(swapped)}/{len(questions)} row(s) swapped")
    if not args.execute or not swapped:
        print("dry run, nothing written" if not args.execute else "nothing to write")
        return 0
    _embed_questions(swapped, 100)
    print(f"written {await write_rewrites(engine, swapped)}")
    return 0


async def load_unlabelled(
    engine: AsyncEngine, *, sample: bool, limit: int | None
) -> list[Question]:
    async with AsyncSession(engine) as session:
        if not sample:
            stmt = select(QuestionRow).where(_unlabelled_clause())
            stmt = stmt.order_by(QuestionRow.created_at)
            if limit:
                stmt = stmt.limit(limit)
            rows = list((await session.scalars(stmt)).all())
        else:
            rows = []
            for lang, n in SAMPLE_PER_LANGUAGE.items():
                stmt = (
                    select(QuestionRow)
                    .where(_unlabelled_clause(), QuestionRow.language == lang)
                    .order_by(func.random())
                    .limit(n)
                )
                rows += (await session.scalars(stmt)).all()
        return [row_to_question(row) for row in rows]


async def write_labels(engine: AsyncEngine, questions: Sequence[Question]) -> int:
    """Persist the provenance (with its verdict) of every checked question."""
    written = 0
    async with engine.begin() as conn:
        for q in questions:
            meta = q.generation_metadata
            if meta is None or "naturalness" not in meta.extra:
                continue
            await conn.execute(
                update(QuestionRow)
                .where(QuestionRow.id == q.id)
                .values(provenance=meta.model_dump(mode="json"))
            )
            written += 1
    return written


def report(questions: Sequence[Question]) -> None:
    by_lang: dict[str, Counter] = {}
    for q in questions:
        meta = q.generation_metadata
        verdict = meta.extra.get("naturalness") if meta else None
        state = "UNCHECKED" if not verdict else "ok" if verdict["ok"] else "flagged"
        by_lang.setdefault(q.language, Counter())[state] += 1
        kinds = ",".join(p["kind"] for p in verdict["problems"]) if verdict else ""
        print(f"{q.language} | {state} | {kinds} | {q.question[:110]}")
    print()
    for lang, counts in sorted(by_lang.items()):
        print(f"{lang}: {counts['flagged']}/{sum(counts.values())} flagged · "
              f"{dict(counts.most_common())}")


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--database-url", default=os.getenv("DATABASE_URL"))
    parser.add_argument("--sample", action="store_true", help="20 sk + 20 cs rows")
    parser.add_argument("--execute", action="store_true", help="write verdicts")
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--model", default=None, help="override LLM_ROLE_NATURALNESS")
    parser.add_argument("--out", default=None, help="write verdicts as JSON here")
    parser.add_argument("--ids", default=None, help="JSON list: re-check these rows")
    parser.add_argument("--apply", default=None, help="JSON list: swap in rewrites")
    parser.add_argument("--applied-by", default=None, help="who approved (--apply)")
    args = parser.parse_args()
    if not args.database_url:
        parser.error("DATABASE_URL / --database-url required")
    if args.apply and not args.applied_by:
        parser.error("--apply needs --applied-by")
    logging.basicConfig(level=logging.WARNING)

    engine = create_async_engine(normalize_async_url(args.database_url))
    if args.apply:
        try:
            return await run_apply(engine, args)
        finally:
            await engine.dispose()
    recorder = llm_usage.UsageRecorder()
    llm_factory.set_usage_handler(llm_usage.UsageCallbackHandler(recorder))
    try:
        if args.ids:
            questions = await load_ids(engine, read_ids(args.ids))
            for q in questions:  # the current prompt replaces the old verdict
                q.generation_metadata.extra.pop("naturalness", None)
        else:
            questions = await load_unlabelled(
                engine, sample=args.sample, limit=args.limit
            )
        print(f"{len(questions)} row(s) selected")
        checker = NaturalnessChecker(model=args.model)
        labelled = await checker.label(questions, batch_size=args.batch_size)
        report(questions)
        if args.out:
            with open(args.out, "w", encoding="utf-8") as fh:
                json.dump(
                    [
                        {
                            "id": q.id,
                            "language": q.language,
                            "question": q.question,
                            "answer": q.correct_answer,
                            "verdict": (q.generation_metadata.extra.get("naturalness")
                                        if q.generation_metadata else None),
                        }
                        for q in questions
                    ],
                    fh,
                    ensure_ascii=False,
                    indent=2,
                )
        written = await write_labels(engine, questions) if args.execute else 0
    finally:
        llm_factory.set_usage_handler(None)
        await engine.dispose()

    cost = recorder.summary()["total_cost_cents_known"]
    print(
        f"checked {labelled}/{len(questions)} · written {written}"
        f"{'' if args.execute else ' (dry run)'} · cost ${cost / 100:.3f}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
