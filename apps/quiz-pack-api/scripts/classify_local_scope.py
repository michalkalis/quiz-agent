#!/usr/bin/env python3
"""#206 backfill: label corpus rows with ``local_scope`` ("local question").

Selects live corpus rows (``pack_id IS NULL``, approved or pending review —
customer packs are private and out of scope) that the classifier has not
labelled yet (no ``provenance.extra.local_scope``), runs
``app.generation.local_scope_classifier`` in batches and writes
``local_scope`` + the verdict back. Resumable by construction: a row that
failed to classify carries no verdict and is picked up by the next run.

Modes::

    cd apps/quiz-pack-api
    # spot check: 20 sk + 20 cs + 10 en random unlabelled rows, nothing written
    DATABASE_URL=... python scripts/classify_local_scope.py --sample
    # full run (dry by default; --execute writes)
    DATABASE_URL=... python scripts/classify_local_scope.py --execute

Prints one ``lang | scope | reason | question`` line per row, a per-language
count of local rows, and the token cost of the run.
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
from app.db.engine import normalize_async_url  # noqa: E402
from app.db.models import QuestionRow, row_to_question  # noqa: E402
from app.generation.local_scope_classifier import (  # noqa: E402
    DEFAULT_BATCH_SIZE,
    LocalScopeClassifier,
)
from quiz_shared.llm import factory as llm_factory  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402
from sqlalchemy import and_, func, or_, select, update  # noqa: E402
from sqlalchemy.ext.asyncio import (  # noqa: E402
    AsyncEngine,
    AsyncSession,
    create_async_engine,
)

logger = logging.getLogger("classify_local_scope")

# Founder spot check (#206): 50 rows, weighted to the native corpora where
# most local questions live.
SAMPLE_PER_LANGUAGE = {"sk": 20, "cs": 20, "en": 10}


def _unlabelled_clause():
    """Live corpus rows without a local-scope verdict."""
    return and_(
        QuestionRow.pack_id.is_(None),
        QuestionRow.review_status.in_(("approved", "pending_review")),
        or_(
            QuestionRow.provenance.is_(None),
            ~QuestionRow.provenance["extra"].has_key("local_scope"),
        ),
    )


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
                lang_clause = (
                    or_(QuestionRow.language == "en", QuestionRow.language.is_(None))
                    if lang == "en"
                    else QuestionRow.language == lang
                )
                stmt = (
                    select(QuestionRow)
                    .where(_unlabelled_clause(), lang_clause)
                    .order_by(func.random())
                    .limit(n)
                )
                rows += (await session.scalars(stmt)).all()
        return [row_to_question(row) for row in rows]


async def write_labels(engine: AsyncEngine, questions: Sequence[Question]) -> int:
    """Persist ``local_scope`` + provenance for every labelled question."""
    written = 0
    async with engine.begin() as conn:
        for q in questions:
            meta = q.generation_metadata
            if meta is None or "local_scope" not in meta.extra:
                continue
            await conn.execute(
                update(QuestionRow)
                .where(QuestionRow.id == q.id)
                .values(
                    local_scope=q.local_scope,
                    provenance=meta.model_dump(mode="json"),
                )
            )
            written += 1
    return written


def report(questions: Sequence[Question]) -> None:
    by_lang: dict[str, Counter] = {}
    for q in questions:
        meta = q.generation_metadata
        verdict = meta.extra.get("local_scope") if meta else None
        lang = q.language or "en"
        scope = verdict["scope"] if verdict else "UNLABELLED"
        by_lang.setdefault(lang, Counter())[scope or "universal"] += 1
        reason = verdict["reason"] if verdict else ""
        print(f"{lang} | {scope or '-'} | {reason} | {q.question[:110]}")
    print()
    for lang, counts in sorted(by_lang.items()):
        total = sum(counts.values())
        local = total - counts["universal"] - counts["UNLABELLED"]
        print(f"{lang}: {local}/{total} local · {dict(counts.most_common())}")


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--database-url", default=os.getenv("DATABASE_URL"))
    parser.add_argument("--sample", action="store_true", help="founder spot check")
    parser.add_argument("--execute", action="store_true", help="write labels")
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--model", default=None, help="override LLM_ROLE_LOCAL_SCOPE")
    parser.add_argument("--out", default=None, help="write verdicts as JSON here")
    args = parser.parse_args()
    if not args.database_url:
        parser.error("DATABASE_URL / --database-url required")
    logging.basicConfig(level=logging.WARNING)

    engine = create_async_engine(normalize_async_url(args.database_url))
    recorder = llm_usage.UsageRecorder()
    llm_factory.set_usage_handler(llm_usage.UsageCallbackHandler(recorder))
    try:
        questions = await load_unlabelled(engine, sample=args.sample, limit=args.limit)
        print(f"{len(questions)} unlabelled row(s) selected")
        classifier = LocalScopeClassifier(model=args.model)
        labelled = await classifier.label(questions, batch_size=args.batch_size)
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
                            "verdict": (q.generation_metadata.extra.get("local_scope")
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
        f"labelled {labelled}/{len(questions)} · written {written}"
        f"{'' if args.execute else ' (dry run)'} · cost ${cost / 100:.3f}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
