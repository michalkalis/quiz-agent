"""PersistStage — writes pack + questions to Postgres (issue #36 task 2.9).

End of the pipeline: by the time we land here, dedup has already trimmed
the question list, so this stage's job is purely a write:

- Insert a `QuestionPack` row with `actual_count = len(ctx.questions)` and
  `generated_at = now()`. `prompt_embedding` stays nullable in Phase 2 —
  the C3 fact-pool cache lookup that consumes it is a Phase 3 (#37)
  concern.
- Insert each `Question` via the `question_to_row` seam, with `pack_id`
  set to the new pack. Embedding fields are normalised so `embedding_model`
  + `embedding_dim` reflect what `embedding` actually holds (the
  text-embedding-3-small / 1536-dim default this codebase has used since
  #33 task 1.5); `embedding_qa_model` gets the same default whenever a
  question carries an `embedding_qa` vector (#170 D2/D10).
- Use `ON CONFLICT (id) DO NOTHING` on the question insert so a re-run of
  the orchestrator with the same question ids is a no-op. The pack itself
  is always created fresh — re-runs allocate a new pack row, which is the
  safe choice given the order→pack 1:1 relationship is enforced at the
  worker layer (task 2.10), not here.

`ctx.pack_id` is set so downstream code (e.g. the worker's order-status
update in 2.10) can link the order to the pack without re-querying. The
`QuestionPack` instance is also published via `StageResult.info["pack"]`
so `PackGenerator.run` can return it directly to its caller — see
`pack_generator.py:90`.
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.db.models import (
    EMBEDDING_DIM,
    PIPELINE_OWNED_COLUMNS,
    GenerationJob,
    GenerationOrder,
    QuestionPack,
    QuestionRow,
    question_to_row,
    row_to_question,
)
from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from quiz_shared.models.question import Question

logger = logging.getLogger(__name__)

DEFAULT_EMBEDDING_MODEL = "text-embedding-3-small"


class PersistStage:
    """Inserts a QuestionPack and its QuestionRows into Postgres."""

    name = "persisting"

    def __init__(self, session_factory: async_sessionmaker[AsyncSession]) -> None:
        self._session_factory = session_factory

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        async with self._session_factory() as session:
            order = await session.get(GenerationOrder, ctx.order_id)
            if order is None:
                raise LookupError(f"GenerationOrder {ctx.order_id} not found")

            pack = QuestionPack(
                order_id=order.id,
                user_id=order.user_id,
                prompt=order.prompt,
                category=order.category,
                theme=order.theme,
                language=order.language,
                target_count=order.target_count,
                actual_count=len(ctx.questions),
                generated_at=datetime.now(timezone.utc),
            )
            session.add(pack)
            await session.flush()  # populate pack.id

            rows = [_question_row_dict(q, pack.id) for q in ctx.questions]
            inserted = 0
            if rows:
                stmt = (
                    pg_insert(QuestionRow.__table__)
                    .values(rows)
                    .on_conflict_do_nothing(index_elements=["id"])
                )
                result = await session.execute(stmt)
                inserted = result.rowcount or 0

            await session.commit()

        ctx.pack_id = pack.id

        return StageResult(
            info={
                "pack": pack,
                "pack_id": str(pack.id),
                "persisted": inserted,
                "questions": len(ctx.questions),
            },
            cost_cents=0,
        )


    # ------------------------------------------------------------------ #182
    # Incremental delivery: the pipeline persists each accepted batch while
    # the rest of the pack is still generating, so a player can start on the
    # first batch. The three methods below are the whole write surface of
    # that mode; `run` above stays the single-shot walk (CLI corpus runs,
    # PACK_BATCH_SCHEDULE=0).

    async def load_existing(self, ctx: OrderContext) -> QuestionPack | None:
        """Resume on the pack a previous attempt already created for this
        order: its questions become `ctx.questions` and are locked. Returns
        None (and leaves ctx untouched) when no pack exists yet."""
        async with self._session_factory() as session:
            pack = (
                await session.execute(
                    select(QuestionPack).where(QuestionPack.order_id == ctx.order_id)
                )
            ).scalars().first()
            if pack is None:
                return None
            rows = (
                await session.execute(
                    select(QuestionRow)
                    .where(QuestionRow.pack_id == pack.id)
                    .order_by(QuestionRow.created_at)
                )
            ).scalars().all()
            session.expunge(pack)
        ctx.pack_id = pack.id
        ctx.questions = [row_to_question(r) for r in rows]
        ctx.locked_count = len(ctx.questions)
        logger.info(
            "PersistStage resumed order_id=%s pack_id=%s with %d persisted questions",
            ctx.order_id, pack.id, ctx.locked_count,
        )
        return pack

    async def persist_batch(
        self, ctx: OrderContext, new_questions: list[Question]
    ) -> QuestionPack:
        """Write one accepted batch. The first call creates the pack
        (`generation_status=generating`) and links `order.pack_id`, which is
        the moment the pack becomes playable. `actual_count` tracks the live
        number of persisted questions."""
        async with self._session_factory() as session:
            order = await session.get(GenerationOrder, ctx.order_id)
            if order is None:
                raise LookupError(f"GenerationOrder {ctx.order_id} not found")
            pack = None
            if ctx.pack_id is not None:
                pack = await session.get(QuestionPack, ctx.pack_id)
            if pack is None:
                pack = QuestionPack(
                    order_id=order.id,
                    user_id=order.user_id,
                    prompt=order.prompt,
                    category=order.category,
                    theme=order.theme,
                    language=order.language,
                    target_count=order.target_count,
                    actual_count=0,
                    generation_status="generating",
                )
                session.add(pack)
                await session.flush()
                order.pack_id = pack.id

            rows = [_question_row_dict(q, pack.id) for q in new_questions]
            inserted = 0
            if rows:
                stmt = (
                    pg_insert(QuestionRow.__table__)
                    .values(rows)
                    .on_conflict_do_nothing(index_elements=["id"])
                )
                inserted = (await session.execute(stmt)).rowcount or 0
            pack.actual_count = (pack.actual_count or 0) + inserted
            pack.generation_status = "generating"
            # Job progress = share of the pack that is playable; the client's
            # bar tracks questions ready, not which stage is running.
            if order.job_id is not None:
                job = await session.get(GenerationJob, order.job_id)
                if job is not None:
                    job.progress = min(
                        int(pack.actual_count / max(pack.target_count, 1) * 100), 99
                    )
            await session.commit()
            session.expunge(pack)
        ctx.pack_id = pack.id
        logger.info(
            "PersistStage batch order_id=%s pack_id=%s inserted=%d ready=%d/%d",
            ctx.order_id, pack.id, inserted, pack.actual_count, pack.target_count,
        )
        return pack

    async def finalize(self, ctx: OrderContext, status: str) -> QuestionPack | None:
        """Close the pack: `complete` (all rounds done) or `failed`. Stamps
        `generated_at` so the row reads like a single-shot pack. No-op when
        this order never created a pack."""
        if ctx.pack_id is None:
            return None
        return await mark_pack(self._session_factory, ctx.pack_id, status)


async def mark_pack(
    session_factory: async_sessionmaker[AsyncSession],
    pack_id: uuid.UUID,
    status: str,
) -> QuestionPack | None:
    """Set `generation_status` on a pack; shared by the pipeline (complete)
    and the worker/sweep failure paths (failed)."""
    async with session_factory() as session:
        pack = await session.get(QuestionPack, pack_id)
        if pack is None:
            return None
        pack.generation_status = status
        if pack.generated_at is None:
            pack.generated_at = datetime.now(timezone.utc)
        await session.commit()
        session.expunge(pack)
    return pack


async def fail_pack_in_session(session: AsyncSession, order: GenerationOrder) -> None:
    """Mark the order's pack `failed` inside the caller's transaction (worker
    final failure, sweep force-fail). No-op when the order has no pack."""
    if order.pack_id is None:
        return
    pack = await session.get(QuestionPack, order.pack_id)
    if pack is not None and pack.generation_status == "generating":
        pack.generation_status = "failed"
        if pack.generated_at is None:
            pack.generated_at = datetime.now(timezone.utc)


def _question_row_dict(question: Any, pack_id: uuid.UUID) -> dict[str, Any]:
    """Build a `{column_name: value}` dict for a dialect-level INSERT.

    Going through `question_to_row` keeps the Pydantic↔ORM seam authoritative —
    if a future field lands on `Question`, this stage picks it up the moment
    `question_to_row` does.
    """
    row = question_to_row(question)
    row.pack_id = pack_id
    if row.id is None:
        row.id = uuid.uuid4()
    if row.embedding is not None:
        if row.embedding_model is None:
            row.embedding_model = DEFAULT_EMBEDDING_MODEL
        if row.embedding_dim is None:
            row.embedding_dim = EMBEDDING_DIM
    if row.embedding_qa is not None and row.embedding_qa_model is None:
        row.embedding_qa_model = DEFAULT_EMBEDDING_MODEL
    return {
        c.name: getattr(row, c.name)
        for c in QuestionRow.__table__.columns
        if c.name not in PIPELINE_OWNED_COLUMNS
    }
