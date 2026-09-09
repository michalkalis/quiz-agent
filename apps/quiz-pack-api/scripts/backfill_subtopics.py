#!/usr/bin/env python3
"""#170 corpus backfill: assign an approved `subtopic` to existing rows (task 170.7).

Why this exists
---------------
Coverage steering allocates the least-covered ``(language, category,
subtopic)`` cell (D1/D3). On a corpus where every ``subtopic`` is NULL every
cell count is 0, so the weighting ``1/(count + K)`` is provably uniform and
the quality guard would measure "a random subtopic", not steering. This
script classifies the rows that already exist into the taxonomy the founder
approved in 170.3 (``app/generation/subtopics.json``) — the only place a
subtopic may come from (locked 5, D4).

Contract
--------
* One batched LLM call per ``--batch-size`` rows of a category, over
  ``LLM_GATEWAY=session`` (#169, zero marginal cost).
* Corpus only: every query filters ``pack_id IS NULL`` (locked 3 / D5) and
  the live review states (``approved`` + ``pending_review``, gate F1 R2).
* Idempotent: only rows with ``subtopic IS NULL`` are sent, so a second run
  costs nothing. ``--force`` re-classifies rows that already carry one.
* **A value outside the approved list exits 1 and writes nothing** — the
  model may never invent a subtopic; a taxonomy that grows by accident is
  a taxonomy nobody approved.
* ``--out`` is always written (the founder's preview); only ``--apply``
  touches the database.

Class `b`: running ``--apply`` against prod is a founder step. Usage::

    cd apps/quiz-pack-api
    DATABASE_URL=... LLM_GATEWAY=session python scripts/backfill_subtopics.py \
        --category science-nature \
        --out ../../docs/testing/runs/170-coverage-steering/subtopic-backfill-preview.json
    # founder reviews the preview, then re-runs the same line with --apply
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
from collections.abc import Sequence
from datetime import UTC, datetime

# Ensure `app.*` imports resolve when invoked as `python scripts/…` from the
# apps/quiz-pack-api/ working dir (same guard as scripts/backfill_embedding_qa.py).
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_APP_DIR = os.path.dirname(_SCRIPT_DIR)
if _APP_DIR in sys.path:
    sys.path.remove(_APP_DIR)
sys.path.insert(0, _APP_DIR)

from app.db.engine import normalize_async_url
from app.db.models import QuestionRow
from app.generation.subtopics import load_subtopics, subtopics_for
from langchain_core.messages import HumanMessage, SystemMessage
from pydantic import BaseModel, Field
from quiz_shared.llm import factory as llm_factory
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

logger = logging.getLogger("backfill_subtopics")

DEFAULT_LANGUAGE = "en"
DEFAULT_BATCH_SIZE = 40
# Gate F1 decision R2: archived / rejected rows are not part of the live
# corpus, so they must not consume steering budget nor a classification call.
LIVE_REVIEW_STATUSES = ("approved", "pending_review")


class BackfillError(ValueError):
    """The classification violates the contract — nothing is written."""


class SubtopicAssignment(BaseModel):
    """One classified row, addressed by its position in the batch."""

    index: int = Field(description="The question's number as given in the list.")
    subtopic: str = Field(description="One subtopic, copied verbatim from the list.")


class SubtopicBatch(BaseModel):
    """Structured answer for one batch (function-calling schema)."""

    assignments: list[SubtopicAssignment] = Field(
        description="Exactly one assignment per question in the batch."
    )


_SYSTEM_PROMPT = """You file existing trivia questions into a fixed subtopic map \
for a spoken quiz app. The map is closed: it was approved by the product owner \
and you may not extend it, rename its entries, or leave a question unfiled. \
Pick the single best fit for each question; when a question straddles two \
subtopics, choose the one a quiz editor would look under first."""

_HUMAN_TEMPLATE = """Category: `{category}` (language: {language})

Approved subtopics for this category — copy one of these strings VERBATIM, \
never invent, merge or reword one:
{approved}

Classify every question below. Return exactly one assignment per question, \
using the number shown in front of it as `index`.

{questions}"""


def build_messages(
    category: str, language: str, approved: Sequence[str], rows: Sequence[tuple]
) -> list:
    questions = "\n".join(
        f"{i}. {question}  (answer: {answer})"
        for i, (_row_id, question, answer) in enumerate(rows)
    )
    human = _HUMAN_TEMPLATE.format(
        category=category,
        language=language,
        approved="\n".join(f"- {name}" for name in approved),
        questions=questions,
    )
    return [SystemMessage(content=_SYSTEM_PROMPT), HumanMessage(content=human)]


def _build_llm(model: str):
    """Chat client on the active gateway (session → subscription, #169)."""
    return llm_factory.chat_openai(
        model, timeout=llm_factory.GENERATION_TIMEOUT, max_tokens=4096
    )


async def classify_batch(
    llm, category: str, language: str, approved: Sequence[str], rows: Sequence[tuple]
) -> SubtopicBatch:
    """One structured call for one batch of rows of a single category."""
    structured = llm.with_structured_output(
        SubtopicBatch, method="function_calling", include_raw=True
    )
    result = await structured.ainvoke(
        build_messages(category, language, approved, rows)
    )
    parsed = result.get("parsed") if isinstance(result, dict) else result
    if not isinstance(parsed, SubtopicBatch):
        error = result.get("parsing_error") if isinstance(result, dict) else None
        raise BackfillError(
            f"{category}: model returned no structured classification "
            f"({error or 'empty'})"
        )
    return parsed


def _normalize(name: str) -> str:
    return " ".join(name.split()).strip().lower()


def resolve_assignments(
    batch: SubtopicBatch,
    rows: Sequence[tuple],
    approved: Sequence[str],
    category: str,
) -> list[tuple]:
    """Map the model's answer onto the batch rows, or raise ``BackfillError``.

    Every row must be classified exactly once and every value must be one of
    the approved names (whitespace/case are forgiven, the stored value is
    always the approved spelling). A row the model skipped, doubled, or filed
    under an invented subtopic aborts the whole run.
    """
    canonical = {_normalize(name): name for name in approved}
    seen: dict[int, str] = {}
    for item in batch.assignments:
        if not 0 <= item.index < len(rows):
            raise BackfillError(
                f"{category}: assignment for question {item.index}, batch has "
                f"{len(rows)}"
            )
        if item.index in seen:
            raise BackfillError(
                f"{category}: question {item.index} classified twice "
                f"({seen[item.index]!r} then {item.subtopic!r})"
            )
        name = canonical.get(_normalize(item.subtopic))
        if name is None:
            raise BackfillError(
                f"{category}: {item.subtopic!r} is not an approved subtopic — "
                "the taxonomy is closed (170.3); refusing to write"
            )
        seen[item.index] = name
    missing = [i for i in range(len(rows)) if i not in seen]
    if missing:
        raise BackfillError(
            f"{category}: {len(missing)} question(s) left unclassified "
            f"(indexes {missing[:10]}) — a partial batch is never written"
        )
    return [
        (row_id, question, seen[i]) for i, (row_id, question, _a) in enumerate(rows)
    ]


async def fetch_rows(
    engine: AsyncEngine,
    category: str,
    language: str,
    *,
    limit: int | None = None,
    force: bool = False,
) -> list[tuple]:
    """Live corpus rows of one category awaiting a subtopic (never pack rows)."""
    stmt = (
        select(QuestionRow.id, QuestionRow.question, QuestionRow.correct_answer)
        .where(
            QuestionRow.pack_id.is_(None),
            QuestionRow.category == category,
            func.coalesce(QuestionRow.language, DEFAULT_LANGUAGE) == language,
            QuestionRow.review_status.in_(LIVE_REVIEW_STATUSES),
        )
        .order_by(QuestionRow.id)
    )
    if not force:
        # Rows classified by a previous run are never re-sent (idempotency).
        stmt = stmt.where(QuestionRow.subtopic.is_(None))
    if limit is not None:
        stmt = stmt.limit(limit)
    async with engine.connect() as conn:
        return [tuple(row) for row in (await conn.execute(stmt)).all()]


async def classify_category(
    engine: AsyncEngine,
    llm,
    category: str,
    language: str,
    *,
    limit: int | None = None,
    batch_size: int = DEFAULT_BATCH_SIZE,
    force: bool = False,
) -> list[tuple]:
    """Every pending row of one category, classified into the approved list."""
    approved = subtopics_for(category, language)
    rows = await fetch_rows(engine, category, language, limit=limit, force=force)
    if not rows:
        logger.info("%s: no rows pending a subtopic", category)
        return []
    resolved: list[tuple] = []
    for start in range(0, len(rows), batch_size):
        batch_rows = rows[start : start + batch_size]
        answer = await classify_batch(llm, category, language, approved, batch_rows)
        resolved.extend(resolve_assignments(answer, batch_rows, approved, category))
        logger.info(
            "%s: batch %d classified (%d row(s))",
            category,
            start // batch_size + 1,
            len(batch_rows),
        )
    return resolved


async def apply_assignments(engine: AsyncEngine, assignments: Sequence[tuple]) -> int:
    """Write the approved subtopic onto the corpus rows (``--apply`` only)."""
    written = 0
    async with engine.begin() as conn:
        for row_id, _question, subtopic in assignments:
            await conn.execute(
                update(QuestionRow)
                .where(QuestionRow.id == row_id, QuestionRow.pack_id.is_(None))
                .values(subtopic=subtopic)
            )
            written += 1
    return written


def build_preview(
    assignments: Sequence[tuple], *, language: str, applied: bool
) -> dict:
    by_category: dict[str, list[dict]] = {}
    for category, row_id, question, subtopic in assignments:
        by_category.setdefault(category, []).append(
            {"id": str(row_id), "question": question, "subtopic": subtopic}
        )
    return {
        "language": language,
        "generated_at": datetime.now(UTC).isoformat(),
        "applied": applied,
        "total": len(assignments),
        "categories": by_category,
    }


def write_preview(path: str, preview: dict) -> None:
    """The founder's audit trail — written on every completed run."""
    out_dir = os.path.dirname(os.path.abspath(path))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(preview, fh, ensure_ascii=False, indent=2)


async def run(args: argparse.Namespace) -> int:
    taxonomy = load_subtopics()
    if args.language not in taxonomy:
        raise BackfillError(
            f"no approved subtopics for language {args.language!r} (170.3)"
        )
    categories = (
        [c.strip() for c in args.category.split(",") if c.strip()]
        if args.category
        else sorted(taxonomy[args.language])
    )
    unknown = [c for c in categories if c not in taxonomy[args.language]]
    if unknown:
        raise BackfillError(
            f"no approved subtopics for {unknown} ({args.language}) — the corpus "
            "may only be steered by a taxonomy the founder approved (170.3)"
        )
    engine = create_async_engine(normalize_async_url(args.database_url), future=True)
    try:
        llm = _build_llm(args.model)
        logger.info(
            "gateway=%s model=%s categories=%s apply=%s",
            llm_factory.gateway(),
            args.model,
            categories,
            args.apply,
        )
        assignments: list[tuple] = []
        for category in categories:
            for row_id, question, subtopic in await classify_category(
                engine,
                llm,
                category,
                args.language,
                limit=args.limit,
                batch_size=args.batch_size,
                force=args.force,
            ):
                assignments.append((category, row_id, question, subtopic))
        written = 0
        if args.apply and assignments:
            written = await apply_assignments(
                engine, [(r, q, s) for _c, r, q, s in assignments]
            )
        preview = build_preview(
            assignments, language=args.language, applied=bool(args.apply)
        )
    finally:
        await engine.dispose()
    write_preview(args.out, preview)
    print(
        f"classified: {len(assignments)} · written: {written} "
        f"({'applied' if args.apply else 'preview only'}) · preview: {args.out}"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Classify existing corpus rows into approved subtopics (#170 task 170.7)."
    )
    p.add_argument("--database-url", default=os.getenv("DATABASE_URL"))
    p.add_argument("--out", required=True, help="Preview JSON path (always written).")
    p.add_argument(
        "--category",
        default=None,
        help="Comma-separated category ids (default: every category in subtopics.json).",
    )
    p.add_argument(
        "--language", default=DEFAULT_LANGUAGE, help="Corpus language (default: en)."
    )
    p.add_argument("--limit", type=int, default=None, help="Max rows per category.")
    p.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    p.add_argument(
        "--force",
        action="store_true",
        help="Re-classify rows that already carry a subtopic.",
    )
    p.add_argument(
        "--apply", action="store_true", help="Write to the DB (default: preview only)."
    )
    p.add_argument(
        "--model",
        default=llm_factory.GEN,
        help="Direct-provider model id; under LLM_GATEWAY=session it maps to the subscription tier.",
    )
    return p


async def run_cli(argv: Sequence[str] | None = None) -> int:
    """Parse + run, turning every contract violation into exit 1 (async so the
    tests can drive it on their own event loop)."""
    args = build_parser().parse_args(argv)
    if not args.database_url:
        logger.error("DATABASE_URL (or --database-url) is required")
        return 1
    try:
        return await run(args)
    except BackfillError as exc:
        logger.error("backfill rejected: %s", exc)
        return 1


def main(argv: Sequence[str] | None = None) -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(levelname)s %(name)s: %(message)s"
    )
    return asyncio.run(run_cli(argv))


if __name__ == "__main__":
    sys.exit(main())
