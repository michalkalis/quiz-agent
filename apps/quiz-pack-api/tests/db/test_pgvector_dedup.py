"""End-to-end DedupStage check against the real pgvector store (#42 task 42.27).

Why this test matters: 42.27 swaps the worker's dedup corpus from frozen
ChromaDB to the canonical pgvector store, reached through the moved
`SyncPgvectorStore` facade. The bridge (sync `find_duplicates` → background
event loop → async store) only exists to make `DedupStage` — whose `run` is
async but calls `find_duplicates` *synchronously* — work against the async
store. This test exercises that exact path against a live DB:

- a fresh near-paraphrase (different id) of a stored question is dropped, and
- re-running the stage on the stored question itself keeps it (self-match
  excluded by id → the orchestrator stays idempotent).

A failure here means the worker would either ship paraphrases of existing
questions or empty the pack on every re-run.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.orchestrator import OrderContext
from app.orchestrator.stages.dedup import DedupStage
from quiz_shared.database.pgvector_client import EMBEDDING_DIM, PgvectorQuestionStore
from quiz_shared.database.sync_pgvector_store import SyncPgvectorStore
from quiz_shared.models.question import Question


class _NullSink:
    """DedupStage.run takes a sink but never calls it; this satisfies the type."""

    async def start_step(self, step: str, info=None) -> int:
        return 0

    async def finish_step(self, step: str, event_id: int, info=None) -> None:
        return None

    async def publish(self, event_id: int, step: str, progress: int, info=None) -> None:
        return None


def _vec(positions: list[int]) -> list[float]:
    vec = [0.0] * EMBEDDING_DIM
    for p in positions:
        vec[p] = 1.0
    return vec


def _make_question(qid: uuid.UUID, text_: str, embedding) -> Question:
    return Question(
        id=str(qid),
        question=text_,
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="general",
        difficulty="easy",
        review_status="approved",
        source="generated",
        embedding=embedding,
        embedding_model="test-fixture",
        embedding_dim=EMBEDDING_DIM,
        created_at=datetime.now(timezone.utc),
    )


def _ctx(questions: list[Question]) -> OrderContext:
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="famous capitals",
        language="en",
        target_count=len(questions),
    )
    ctx.questions = list(questions)
    return ctx


@pytest.mark.asyncio
async def test_dedupstage_drops_pgvector_paraphrase_keeps_self(
    engine: AsyncEngine,
) -> None:
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

    base = [0, 1, 2, 3, 4, 5, 6, 7]
    # Deterministic embedder keyed on query text (no OpenAI call):
    #   the paraphrase shares 7/8 positions -> cosine ~0.935 (>= 0.85)
    #   the stored question's own text -> cosine 1.0 (the self-match case)
    embeds = {
        "Capital of France?": _vec(base),
        "What is the capital city of France?": _vec(base[:7]),
    }

    def fake_embedder(query: str) -> list[float]:
        return embeds[query]

    # Seed via the fixture engine (bound to the test event loop). The dedup
    # store gets its OWN engine over the same DB, so every query it runs goes
    # through the SyncPgvectorStore background loop without ever sharing the
    # test-loop-bound fixture engine across loops. This mirrors production: the
    # worker's PgvectorQuestionStore is only ever reached via the sync bridge.
    seed_store = PgvectorQuestionStore(session_factory=factory)
    dedup_async = PgvectorQuestionStore(
        database_url=engine.url.render_as_string(hide_password=False),
        embedder=fake_embedder,
    )
    sync_store = SyncPgvectorStore(dedup_async)

    seeded_id = uuid.uuid4()
    seeded = _make_question(seeded_id, "Capital of France?", _vec(base))

    try:
        assert await seed_store.add(seeded) is True

        # A new near-paraphrase (distinct id) must be dropped as a cosine dup.
        paraphrase = _make_question(
            uuid.uuid4(), "What is the capital city of France?", None
        )
        ctx = _ctx([paraphrase])
        result = await DedupStage(sync_store, gold_standard_path=None).run(
            ctx, _NullSink()
        )
        assert result.info == {"kept": 0, "dropped": 1}
        assert ctx.questions == []

        # Re-running on the stored question itself keeps it — the only match is
        # its own id, which DedupStage excludes (idempotent re-run).
        ctx_self = _ctx([seeded])
        result_self = await DedupStage(sync_store, gold_standard_path=None).run(
            ctx_self, _NullSink()
        )
        assert result_self.info == {"kept": 1, "dropped": 0}
        assert ctx_self.questions == [seeded]
    finally:
        async with factory() as session:
            await session.execute(
                text("DELETE FROM questions WHERE id = :a"), {"a": seeded_id}
            )
            await session.commit()
