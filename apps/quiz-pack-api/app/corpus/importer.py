"""Question batch → Postgres ``questions`` importer core (#72 corpus swap, #202).

Library home of what ``scripts/import_questions_json.py`` used to hold inline,
so the weekly fresh-topup job (#202) and the CLI run the SAME guard, review
status decision, embedding and insert code (one definition, no fork).

Order of operations in :func:`import_questions`:

1. #158 fail-closed guard — rows the verifier held / failed never enter.
2. De-duplicate by id (first surviving row wins).
3. Review status (#177): ``review_status="auto"`` decides per row via the
   machine-approval predicate (``approved`` + ``reviewed_by=machine:gates-v1``
   when every gate cleared, else ``pending_review``); an explicit status is
   forced onto every row (the human promotion / quarantine path). Auto-approve
   is allowed for en/sk/cs (``app.scoring.machine_approval``).
4. Existing ids are skipped; the rest are embedded (question + question/answer
   vectors, #170 D2/D10) and inserted idempotently on the primary key.

``execute=False`` stops after step 3 plus the id lookup: nothing is embedded or
written (the OpenAI key is not needed).
"""

from __future__ import annotations

import json
import logging
import os
import uuid
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

from openai import OpenAI
from quiz_shared.models.question import Question
from quiz_shared.utils.qa_text import qa_text
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, create_async_engine

from app import feature_flags
from app.db import (
    PIPELINE_OWNED_COLUMNS,
    QuestionRow,
    engine,
    normalize_async_url,
    question_to_row,
)
from app.generation.local_scope_classifier import (
    LocalScopeClassifier,
    has_local_scope_verdict,
)
from app.scoring.machine_approval import (
    GATE_VERSION,
    machine_approval_block_reason,
    tf_imbalance_excess_ids,
)

logger = logging.getLogger("import_questions_json")

EMBEDDING_MODEL = "text-embedding-3-small"
EMBEDDING_DIM = 1536

# `review_status="auto"` (the default, #177): decide per row via the machine
# approval predicate instead of stamping one status on the whole batch.
AUTO_REVIEW_STATUS = "auto"


class EmbeddingKeyMissing(RuntimeError):
    """Rows need embeddings but ``OPENAI_API_KEY`` is not set."""


@dataclass
class ImportResult:
    """What an import did (or, with ``execute=False``, would do).

    ``approved`` / ``pending`` / ``needs_embedding`` count the rows that are
    about to be inserted (``to_insert``); ``block_reasons`` counts why rows
    stayed pending across ALL unique rows (auto mode only), so a dry run shows
    a systematic miss instead of only "0 approved".
    """

    unique: int = 0
    already_present: int = 0
    to_insert: int = 0
    approved: int = 0
    pending: int = 0
    needs_embedding: int = 0
    inserted: int = 0
    # #206: rows the local-scope classifier labelled during this import.
    local_scope_labelled: int = 0
    # question id -> reason the #158 guard kept it out of the corpus.
    skipped: dict[str, str] = field(default_factory=dict)
    # reason -> number of unique rows left pending (auto mode only).
    block_reasons: dict[str, int] = field(default_factory=dict)
    # question id -> reason that row stayed pending (auto mode only).
    pending_reasons: dict[str, str] = field(default_factory=dict)
    # Final status per surviving (unique) question id.
    statuses: dict[str, str] = field(default_factory=dict)


def _verification_block_reason(q: Question) -> str | None:
    """#158 fail-closed corpus guard: why this row must NOT be imported.

    A pipeline row the verifier held (`held_for_review`) or explicitly failed
    (`verified: False`) never enters the corpus, under any review status.
    Rows without verification keys (hand-curated content that never ran the
    pipeline) are not blocked — the guard targets pipeline provenance.
    """
    extra = q.generation_metadata.extra if q.generation_metadata else {}
    if extra.get("held_for_review"):
        return "held_for_review"
    if extra.get("verified") is False:
        return "verified=False"
    return None


def _apply_auto_review_status(
    questions: list[Question], per_question: dict[str, str] | None = None
) -> dict[str, int]:
    """Stamp ``approved`` / ``pending_review`` per row (#177); return reasons.

    ``approved`` here means "every machine gate cleared with zero findings",
    marked ``reviewed_by=machine:gates-v1`` so it stays distinguishable from a
    human verdict (`reviewed_by LIKE 'machine:%'`). The returned dict maps
    block reason → row count, so a dry run shows WHY rows stayed pending
    instead of only how many. ``per_question`` (optional) collects id → reason.
    """
    tf_excess = tf_imbalance_excess_ids(questions)
    now = datetime.now(UTC)
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
        if per_question is not None:
            per_question[q.id] = reason
    return reasons


def parse_questions(raw_rows: Iterable[dict], review_status: str) -> list[Question]:
    """Validate raw dicts into ``Question`` objects (no guard, no dedup).

    The payload carries the requested status exactly as the CLI always did
    (``pending_review`` for auto mode, the forced status otherwise), plus the
    embedding model/dim defaults the INSERT needs.
    """
    row_status = "pending_review" if review_status == AUTO_REVIEW_STATUS else review_status
    questions: list[Question] = []
    for raw in raw_rows:
        payload = {**raw, "review_status": row_status}
        payload.setdefault("embedding_model", EMBEDDING_MODEL)
        payload.setdefault("embedding_dim", EMBEDDING_DIM)
        questions.append(Question.model_validate(payload))
    return questions


def parse_question_files(paths: Sequence[Path], review_status: str) -> list[Question]:
    """Read JSON batch files (each a list of ``Question`` dicts) and parse them."""
    questions: list[Question] = []
    for path in paths:
        raw_list = json.loads(path.read_text())
        questions.extend(parse_questions(raw_list, review_status))
        logger.info("Read %d row(s) from %s", len(raw_list), path)
    return questions


def prepare_questions(
    questions: Iterable[Question],
    review_status: str = AUTO_REVIEW_STATUS,
    stats: dict | None = None,
) -> list[Question]:
    """Guard (#158), de-duplicate by id, stamp the review status.

    The #158 guard runs FIRST either way — a held/failed row never enters the
    corpus, so it never reaches the approval predicate. An explicit status is
    forced onto every surviving row. ``stats`` (optional) receives
    ``skipped`` (id → guard reason), ``block_reasons`` and ``pending_reasons``
    (auto mode only).
    """
    by_id: dict[str, Question] = {}
    skipped: dict[str, str] = {}
    for q in questions:
        reason = _verification_block_reason(q)
        if reason is not None:
            skipped[q.id] = reason
            logger.error(
                "REJECTED (fail-closed, #158): id=%s %s — unverified/held "
                "questions never enter the corpus. Question: %.80s",
                q.id,
                reason,
                q.question,
            )
            continue
        by_id.setdefault(q.id, q)
    prepared = list(by_id.values())
    if stats is not None:
        stats["skipped"] = skipped
    if review_status == AUTO_REVIEW_STATUS:
        pending_reasons: dict[str, str] = {}
        block_reasons = _apply_auto_review_status(prepared, pending_reasons)
        if stats is not None:
            stats["block_reasons"] = block_reasons
            stats["pending_reasons"] = pending_reasons
    else:
        for q in prepared:
            q.review_status = review_status
    return prepared


def _batched(items: Sequence, size: int) -> Iterable[Sequence]:
    for i in range(0, len(items), size):
        yield items[i:i + size]


def _embed_batch(client: OpenAI, texts: list[str]) -> list[list[float]]:
    response = client.embeddings.create(model=EMBEDDING_MODEL, input=texts)
    return [d.embedding for d in response.data]


async def _existing_ids(session: AsyncSession, ids: Sequence[str]) -> set[str]:
    if not ids:
        return set()
    uuids = [uuid.UUID(i) for i in ids]
    result = await session.execute(
        select(QuestionRow.id).where(QuestionRow.id.in_(uuids))
    )
    return {str(row[0]) for row in result.all()}


def _row_to_insert_dict(row: QuestionRow) -> dict:
    """Plain ``{column_name: value}`` dict for a dialect-level INSERT.

    ``PIPELINE_OWNED_COLUMNS`` is excluded: those columns are not this writer's
    to set, and a transient ORM object has not yet had its Python-side defaults
    applied, so sending them would insert an explicit NULL.
    """
    return {
        c.name: getattr(row, c.name)
        for c in QuestionRow.__table__.columns
        if c.name not in PIPELINE_OWNED_COLUMNS
    }


def _embed_questions(needs_embedding: list[Question], batch_size: int) -> None:
    """Fill ``embedding`` and ``embedding_qa`` in place (#170 D2/D10).

    One OpenAI call per batch: question texts first, then the matching
    question+answer texts (same order, same model).
    """
    batches = (len(needs_embedding) + batch_size - 1) // batch_size
    client = OpenAI()
    for i, batch in enumerate(_batched(needs_embedding, batch_size), 1):
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


async def import_questions(
    questions: Iterable[Question],
    *,
    database_url_or_engine: str | AsyncEngine | None = None,
    review_status: str = AUTO_REVIEW_STATUS,
    execute: bool,
    batch_size: int = 100,
    on_plan: Callable[[ImportResult], None] | None = None,
    local_scope_classifier: LocalScopeClassifier | None = None,
) -> ImportResult:
    """Guard, stamp, embed and insert ``questions``; return what happened.

    ``database_url_or_engine``: a URL (an engine is created and disposed here),
    an ``AsyncEngine`` (borrowed, never disposed), or ``None`` for the app's
    default engine. ``on_plan`` is called once with the counts after planning
    and before any write, so a caller can report even when embedding then
    fails. Raises :class:`EmbeddingKeyMissing` when rows need vectors and
    ``execute`` is on but ``OPENAI_API_KEY`` is unset (nothing is written).
    ``local_scope_classifier`` overrides the default #206 labeller (tests).
    """
    stats: dict = {}
    prepared = prepare_questions(questions, review_status, stats)

    if isinstance(database_url_or_engine, str):
        async_engine = create_async_engine(
            normalize_async_url(database_url_or_engine), future=True
        )
        owned_engine = True
    elif database_url_or_engine is None:
        async_engine = engine
        owned_engine = False
    else:
        async_engine = database_url_or_engine
        owned_engine = False

    try:
        async with AsyncSession(async_engine, expire_on_commit=False) as session:
            existing = await _existing_ids(session, [q.id for q in prepared])

        to_insert = [q for q in prepared if q.id not in existing]
        # #170 D2/D10: every imported row carries BOTH vectors — the question
        # embedding (retrieval + question-only dedup) and the question+answer
        # embedding (`embedding_qa`, the QA dedup branch) — so the corpus never
        # needs a paid backfill for rows that went through this importer.
        needs_embedding = [
            q for q in to_insert if q.embedding is None or q.embedding_qa is None
        ]
        result = ImportResult(
            unique=len(prepared),
            already_present=len(existing),
            to_insert=len(to_insert),
            approved=sum(1 for q in to_insert if q.review_status == "approved"),
            pending=sum(1 for q in to_insert if q.review_status != "approved"),
            needs_embedding=len(needs_embedding),
            skipped=stats["skipped"],
            block_reasons=stats.get("block_reasons", {}),
            pending_reasons=stats.get("pending_reasons", {}),
            statuses={q.id: q.review_status for q in prepared},
        )
        if on_plan is not None:
            on_plan(result)

        if not execute:
            return result

        if needs_embedding:
            if not os.getenv("OPENAI_API_KEY"):
                raise EmbeddingKeyMissing(
                    f"OPENAI_API_KEY not set; cannot embed {len(needs_embedding)} row(s)."
                )
            _embed_questions(needs_embedding, batch_size)

        # #206: every new corpus row gets its "local question" label here, the
        # one place all corpus writers (CLI import, weekly fresh job, native
        # sk/cs runs) pass through, so new rows are labelled exactly like the
        # backfilled corpus. A row the classifier misses goes in unlabelled
        # (= universal) and the backfill script picks it up later.
        if feature_flags.local_scope_classification():
            unlabelled = [q for q in to_insert if not has_local_scope_verdict(q)]
            if unlabelled:
                labeller = local_scope_classifier or LocalScopeClassifier()
                result.local_scope_labelled = await labeller.label(unlabelled)

        rows = [_row_to_insert_dict(question_to_row(q)) for q in to_insert]
        if rows:
            async with async_engine.begin() as conn:
                stmt = (
                    pg_insert(QuestionRow.__table__)
                    .values(rows)
                    .on_conflict_do_nothing(index_elements=["id"])
                )
                insert_result = await conn.execute(stmt)
                result.inserted = insert_result.rowcount or 0
        return result
    finally:
        if owned_engine:
            await async_engine.dispose()
