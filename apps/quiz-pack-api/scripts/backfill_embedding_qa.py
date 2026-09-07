#!/usr/bin/env python3
"""#170 corpus backfill: `answer_key` + `language` (free) and `embedding_qa` (paid).

Two passes over corpus rows (``pack_id IS NULL`` — customer packs are never
touched, locked 3 / D5), both idempotent and batched like the importer:

``--answer-key-only`` (D2/A2, **no network, no OpenAI key needed**)
    ``answer_key = _normalize_answer(correct_answer)`` where NULL (imported
    from ``dedup.py`` — the cap must count exactly what dedup compares, so
    the normaliser is never re-implemented here) and ``language = 'en'``
    where NULL (questions are English-only until the founder says otherwise;
    the coverage map and the cap are keyed by language, so NULL rows would
    silently vanish from both).

default (paid, D2/D10)
    Runs the free pass first, then embeds ``question + answer`` into
    ``embedding_qa`` (+ ``embedding_qa_model``) for rows where it is NULL —
    text-embedding-3-small, cents for a corpus in the low thousands. Ends
    with a one-line ``EXPLAIN`` of the QA dedup query and **warns if the
    planner picked an ivfflat index scan** (D9: that is the "time for HNSW"
    signal; today the table is small enough for a seq scan).

Class `b`: run against prod only as a founder step. Usage::

    cd apps/quiz-pack-api
    DATABASE_URL=... python scripts/backfill_embedding_qa.py --answer-key-only
    DATABASE_URL=... OPENAI_API_KEY=... python scripts/backfill_embedding_qa.py
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import sys
from collections.abc import Callable, Sequence
from typing import Any

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_APP_DIR = os.path.dirname(_SCRIPT_DIR)
if _APP_DIR in sys.path:
    sys.path.remove(_APP_DIR)
sys.path.insert(0, _APP_DIR)

from app.db.engine import normalize_async_url
from app.db.models import QuestionRow
from app.orchestrator.stages.dedup import _normalize_answer
from sqlalchemy import select, text, update
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

logger = logging.getLogger("backfill_embedding_qa")

EMBEDDING_MODEL = "text-embedding-3-small"
DEFAULT_LANGUAGE = "en"
DEFAULT_BATCH_SIZE = 64

EmbedFn = Callable[[Sequence[str]], Sequence[Sequence[float]]]


def qa_text(question: str, correct_answer: Any, possible_answers: dict | None) -> str:
    """The text that gets embedded: question + the answer as the player hears it.

    MCQ rows store the option TEXT in ``correct_answer`` since the 2026-07-11
    pilot fix; a bare option letter (legacy rows) is resolved through
    ``possible_answers`` so two rows with the same fact embed the same way.
    """
    answer = correct_answer
    if isinstance(possible_answers, dict) and isinstance(answer, str):
        answer = possible_answers.get(answer, answer)
    return f"Question: {question}\nAnswer: {answer}"


async def backfill_answer_keys(
    engine: AsyncEngine, *, batch_size: int = DEFAULT_BATCH_SIZE, dry_run: bool = False
) -> dict[str, int]:
    """Free pass: fill NULL ``answer_key`` and NULL ``language`` on corpus rows."""
    updated_keys = 0
    async with engine.begin() as conn:
        rows = (
            await conn.execute(
                select(QuestionRow.id, QuestionRow.correct_answer)
                .where(QuestionRow.pack_id.is_(None), QuestionRow.answer_key.is_(None))
                .order_by(QuestionRow.id)
            )
        ).all()
        for start in range(0, len(rows), batch_size):
            batch = rows[start : start + batch_size]
            if dry_run:
                updated_keys += len(batch)
                continue
            for row_id, correct_answer in batch:
                await conn.execute(
                    update(QuestionRow)
                    .where(QuestionRow.id == row_id)
                    .values(answer_key=_normalize_answer(correct_answer)[:255])
                )
                updated_keys += 1
        lang_stmt = (
            update(QuestionRow)
            .where(QuestionRow.pack_id.is_(None), QuestionRow.language.is_(None))
            .values(language=DEFAULT_LANGUAGE)
        )
        if dry_run:
            updated_lang = (
                await conn.execute(
                    select(text("count(*)"))
                    .select_from(QuestionRow)
                    .where(
                        QuestionRow.pack_id.is_(None), QuestionRow.language.is_(None)
                    )
                )
            ).scalar_one()
        else:
            updated_lang = (await conn.execute(lang_stmt)).rowcount or 0
    logger.info(
        "answer_key: %d row(s) %s · language: %d row(s) %s",
        updated_keys,
        "would be updated" if dry_run else "updated",
        updated_lang,
        "would be set to 'en'" if dry_run else "set to 'en'",
    )
    return {"answer_key": updated_keys, "language": int(updated_lang)}


async def backfill_qa_embeddings(
    engine: AsyncEngine,
    embed: EmbedFn,
    *,
    batch_size: int = DEFAULT_BATCH_SIZE,
    dry_run: bool = False,
) -> dict[str, int]:
    """Paid pass: embed question+answer where ``embedding_qa`` is NULL."""
    async with engine.connect() as conn:
        rows = (
            await conn.execute(
                select(
                    QuestionRow.id,
                    QuestionRow.question,
                    QuestionRow.correct_answer,
                    QuestionRow.possible_answers,
                )
                .where(
                    QuestionRow.pack_id.is_(None), QuestionRow.embedding_qa.is_(None)
                )
                .order_by(QuestionRow.id)
            )
        ).all()
    if dry_run:
        logger.info("embedding_qa: %d row(s) would be embedded", len(rows))
        return {"embedded": 0, "pending": len(rows), "calls": 0}
    embedded = calls = 0
    for start in range(0, len(rows), batch_size):
        batch = rows[start : start + batch_size]
        vectors = embed([qa_text(q, a, pa) for _, q, a, pa in batch])
        calls += 1
        if len(vectors) != len(batch):
            raise RuntimeError(
                f"embedder returned {len(vectors)} vectors for {len(batch)} texts"
            )
        async with engine.begin() as conn:
            for (row_id, *_), vec in zip(batch, vectors):
                await conn.execute(
                    update(QuestionRow)
                    .where(QuestionRow.id == row_id)
                    .values(embedding_qa=list(vec), embedding_qa_model=EMBEDDING_MODEL)
                )
                embedded += 1
        logger.info("embedding_qa: batch %d (%d row(s))", calls, len(batch))
    logger.info("embedding_qa: %d row(s) embedded in %d call(s)", embedded, calls)
    return {"embedded": embedded, "pending": 0, "calls": calls}


# The QA dedup query shape (170.10): threshold in SQL, LIMIT after the filter.
_EXPLAIN_SQL = text(
    "EXPLAIN SELECT id FROM questions "
    "WHERE pack_id IS NULL AND embedding_qa IS NOT NULL "
    "AND (embedding_qa <=> CAST(:probe AS vector)) <= 0.1 "
    "ORDER BY embedding_qa <=> CAST(:probe AS vector) LIMIT 10"
)


async def explain_dedup_query(engine: AsyncEngine, dim: int = 1536) -> str:
    probe = "[" + ",".join(["0"] * dim) + "]"
    async with engine.connect() as conn:
        rows = (await conn.execute(_EXPLAIN_SQL, {"probe": probe})).all()
    return "\n".join(str(r[0]) for r in rows)


def warn_if_ivfflat(plan: str, log: logging.Logger = logger) -> bool:
    """D9 tripwire: an ivfflat index scan on the dedup query means the planner
    now trusts an index built for far more rows (lists=100, probes=1 → ~1 %
    of rows read) — recall would silently drop. Time to revisit HNSW."""
    if "ivfflat" in plan.lower() and "index scan" in plan.lower():
        log.warning(
            "D9: the dedup query uses an ivfflat index scan — dedup recall may be "
            "degraded; revisit the vector index (HNSW). Plan:\n%s",
            plan,
        )
        return True
    logger.info("D9 check: dedup query plan is not an ivfflat index scan")
    return False


def _openai_embedder() -> EmbedFn:
    from openai import OpenAI

    client = OpenAI()

    def embed(texts: Sequence[str]) -> list[list[float]]:
        response = client.embeddings.create(model=EMBEDDING_MODEL, input=list(texts))
        return [list(item.embedding) for item in response.data]

    return embed


async def run(args: argparse.Namespace, embed: EmbedFn | None = None) -> int:
    engine = create_async_engine(normalize_async_url(args.database_url), future=True)
    try:
        counts = await backfill_answer_keys(
            engine, batch_size=args.batch_size, dry_run=args.dry_run
        )
        print(
            f"answer_key filled: {counts['answer_key']} · language set: {counts['language']}"
        )
        if args.answer_key_only:
            return 0
        if embed is None:
            if not args.dry_run and not os.getenv("OPENAI_API_KEY"):
                logger.error("OPENAI_API_KEY not set; the QA embedding pass is paid")
                return 2
            embed = _openai_embedder() if not args.dry_run else (lambda texts: [])
        qa = await backfill_qa_embeddings(
            engine, embed, batch_size=args.batch_size, dry_run=args.dry_run
        )
        print(
            f"embedding_qa embedded: {qa['embedded']} · pending: {qa['pending']} · "
            f"OpenAI calls: {qa['calls']}"
        )
        warn_if_ivfflat(await explain_dedup_query(engine))
        return 0
    finally:
        await engine.dispose()


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--database-url", default=os.getenv("DATABASE_URL"))
    p.add_argument(
        "--answer-key-only",
        action="store_true",
        help="Free pass only: answer_key + language='en'; no network call.",
    )
    p.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    p.add_argument("--dry-run", action="store_true", help="Count only, write nothing.")
    return p


def main(argv: Sequence[str] | None = None) -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(levelname)s %(name)s: %(message)s"
    )
    args = build_parser().parse_args(argv)
    if not args.database_url:
        logger.error("DATABASE_URL (or --database-url) is required")
        return 1
    return asyncio.run(run(args))


if __name__ == "__main__":
    sys.exit(main())
