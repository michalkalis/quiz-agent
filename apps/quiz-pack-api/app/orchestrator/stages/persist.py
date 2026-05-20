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
  #33 task 1.5).
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

import uuid
from datetime import datetime, timezone
from typing import Any

from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.db.models import (
    EMBEDDING_DIM,
    GenerationOrder,
    QuestionPack,
    QuestionRow,
    question_to_row,
)
from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink

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
    return {c.name: getattr(row, c.name) for c in QuestionRow.__table__.columns}
