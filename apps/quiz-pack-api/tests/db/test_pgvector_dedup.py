"""End-to-end DedupStage check against the real pgvector store (#42 task 42.27).

Why this test matters: 42.27 swaps the worker's dedup corpus from frozen
ChromaDB to the canonical pgvector store. Since #150 `DedupStage` awaits that
async store directly on the worker loop (the `SyncPgvectorStore` bridge it
used to go through blocked the loop for every embedding + query). This test
exercises that exact path against a live DB:

- a fresh near-paraphrase (different id) of a stored question is dropped, and
- re-running the stage on the stored question itself keeps it (self-match
  excluded by id → the orchestrator stays idempotent).

A failure here means the worker would either ship paraphrases of existing
questions or empty the pack on every re-run.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

import pytest
from app.db.models import GenerationOrder, QuestionPack
from app.orchestrator import OrderContext
from app.orchestrator.stages.dedup import DedupStage
from quiz_shared.database.pgvector_client import EMBEDDING_DIM, PgvectorQuestionStore
from quiz_shared.models.question import Question
from quiz_shared.utils.qa_text import qa_text
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker


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
        created_at=datetime.now(UTC),
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
    # store gets its OWN engine over the same DB — mirroring production, where
    # `on_startup` builds it from the session factory's URL rather than sharing
    # AsyncSessionLocal's engine (#139 pool poisoning).
    seed_store = PgvectorQuestionStore(session_factory=factory)
    dedup_store = PgvectorQuestionStore(
        database_url=engine.url.render_as_string(hide_password=False),
        embedder=fake_embedder,
    )

    seeded_id = uuid.uuid4()
    seeded = _make_question(seeded_id, "Capital of France?", _vec(base))

    try:
        assert await seed_store.add(seeded) is True

        # A new near-paraphrase (distinct id) must be dropped as a cosine dup.
        paraphrase = _make_question(
            uuid.uuid4(), "What is the capital city of France?", None
        )
        ctx = _ctx([paraphrase])
        result = await DedupStage(dedup_store, gold_standard_path=None).run(
            ctx, _NullSink()
        )
        # #170 added `answer_cap` + `drop_reasons`; the legacy triple must hold.
        assert {k: result.info[k] for k in ("kept", "dropped", "fact_dropped")} == {
            "kept": 0,
            "dropped": 1,
            "fact_dropped": 0,
        }
        assert ctx.questions == []

        # Re-running on the stored question itself keeps it — the only match is
        # its own id, which DedupStage excludes (idempotent re-run).
        ctx_self = _ctx([seeded])
        result_self = await DedupStage(dedup_store, gold_standard_path=None).run(
            ctx_self, _NullSink()
        )
        assert {
            k: result_self.info[k] for k in ("kept", "dropped", "fact_dropped")
        } == {"kept": 1, "dropped": 0, "fact_dropped": 0}
        assert ctx_self.questions == [seeded]
    finally:
        async with factory() as session:
            await session.execute(
                text("DELETE FROM questions WHERE id = :a"), {"a": seeded_id}
            )
            await session.commit()


# ── #170 D2 — QA embedding branch against the live column ────────────────────
#
# Why: `find_duplicates` (question-only, hot path, locked) takes the 10 nearest
# rows and THEN applies the threshold, so an 11th match above threshold is
# never seen. `find_duplicates_qa` filters in SQL and bounds only above the
# filter — the replay harness (170.14b) and Session K's diff need every pair.
# The A14 leg: a customer-pack row must never influence a corpus decision.


def _qa_vec(shared: int) -> list[float]:
    """First `shared` of 100 positions set: cosine to the full 100-position
    vector is sqrt(shared / 100) — 90 → 0.949, 81 → 0.90, 70 → 0.837."""
    return _vec(list(range(shared)))


def _vector_literal(vec: list[float]) -> str:
    return "[" + ",".join(f"{x:.1f}" for x in vec) + "]"


async def _set_embedding_qa(
    factory: async_sessionmaker[AsyncSession], qid: uuid.UUID, vec: list[float]
) -> None:
    # `embedding_qa` is deliberately absent from the shared mirror table, so
    # the seed goes through SQL exactly like the backfill script's UPDATE.
    async with factory() as session:
        await session.execute(
            text("UPDATE questions SET embedding_qa = CAST(:vec AS vector) WHERE id = :id"),
            {"vec": _vector_literal(vec), "id": qid},
        )
        await session.commit()


async def _make_pack(factory: async_sessionmaker[AsyncSession]) -> tuple[uuid.UUID, uuid.UUID]:
    async with factory() as session:
        order = GenerationOrder(
            transaction_id=f"qa-dedup-tx-{uuid.uuid4().hex}",
            product_id="pack_10",
            prompt="qa dedup pack leg",
            category="general",
            theme="air",
            target_count=1,
            language="en",
            status="in_progress",
        )
        session.add(order)
        await session.flush()
        pack = QuestionPack(
            order_id=order.id,
            user_id=order.user_id,
            prompt=order.prompt,
            category=order.category,
            theme=order.theme,
            language=order.language,
            target_count=1,
            actual_count=1,
            generated_at=datetime.now(UTC),
        )
        session.add(pack)
        await session.commit()
        return order.id, pack.id


async def _cleanup(
    factory: async_sessionmaker[AsyncSession],
    question_ids: list[uuid.UUID],
    order_id: uuid.UUID | None = None,
) -> None:
    async with factory() as session:
        await session.execute(
            text("DELETE FROM questions WHERE id = ANY(:ids)"), {"ids": question_ids}
        )
        if order_id is not None:
            await session.execute(
                text("DELETE FROM generation_orders WHERE id = :oid"), {"oid": order_id}
            )
        await session.commit()


@pytest.mark.asyncio
async def test_find_duplicates_qa_returns_every_match_above_threshold(
    engine: AsyncEngine,
) -> None:
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    question_text = "Which element makes up most of the air?"
    qa_query = qa_text(question_text, "Nitrogen", None)

    def fake_embedder(query: str) -> list[float]:
        assert query == qa_query, f"unexpected embed input: {query!r}"
        return _qa_vec(100)

    seed_store = PgvectorQuestionStore(session_factory=factory)
    qa_store = PgvectorQuestionStore(
        database_url=engine.url.render_as_string(hide_password=False),
        embedder=fake_embedder,
    )

    # 11 live rows above threshold (cosine 1.0 down to 0.949 by construction)
    # plus three rows that must NEVER come back: one below threshold, one
    # customer-pack row and one archived (culled) row — the last two sit at
    # cosine 1.0, so only the predicates can keep them out.
    live_ids = [uuid.uuid4() for _ in range(11)]
    below_id, pack_row_id, archived_id = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    order_id, pack_id = await _make_pack(factory)
    try:
        for i, qid in enumerate(live_ids):
            assert await seed_store.add(
                _make_question(qid, f"Live corpus row {i}", _vec([200 + i]))
            )
            await _set_embedding_qa(factory, qid, _qa_vec(100 - i))
        # Every seed carries a question vector: `add` would otherwise call the
        # real embedder for the (irrelevant here) `embedding` column.
        assert await seed_store.add(_make_question(below_id, "Below threshold", _vec([300])))
        await _set_embedding_qa(factory, below_id, _qa_vec(70))
        pack_row = _make_question(pack_row_id, "Customer pack row", _vec([301]))
        pack_row.pack_id = str(pack_id)
        assert await seed_store.add(pack_row)
        await _set_embedding_qa(factory, pack_row_id, _qa_vec(100))
        archived = _make_question(archived_id, "Archived corpus row", _vec([302]))
        archived.review_status = "archived"
        assert await seed_store.add(archived)
        await _set_embedding_qa(factory, archived_id, _qa_vec(100))

        matches = await qa_store.find_duplicates_qa(question_text, "Nitrogen")

        returned = [uuid.UUID(q.id) for q, _ in matches]
        scores = [s for _, s in matches]
        assert len(returned) == 11, "LIMIT-10-before-threshold would have cut the 11th"
        assert returned == live_ids  # complete AND ordered most-similar first
        assert scores == sorted(scores, reverse=True)
        assert min(scores) >= 0.90
        assert below_id not in returned
        assert pack_row_id not in returned  # A14 — pack rows never decide corpus dedup
        assert archived_id not in returned  # gate F1 R2 — live corpus only
    finally:
        await _cleanup(factory, live_ids + [below_id, pack_row_id, archived_id], order_id)


@pytest.mark.asyncio
async def test_dedupstage_qa_branch_drops_same_fact_disjoint_wording(
    engine: AsyncEngine,
) -> None:
    """End to end over the real column: the question-only branch sees an
    orthogonal question vector (no drop), the QA branch sees an identical
    question+answer vector and drops; then a live row with `embedding` but no
    `embedding_qa` makes the stage refuse to run at all."""
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    corpus_q = "Which element makes up most of the air we breathe?"
    candidate_q = "What gas accounts for roughly 78% of Earth's atmosphere?"
    embeds = {
        corpus_q: _vec([0, 1, 2, 3]),
        candidate_q: _vec([10, 11, 12, 13]),  # orthogonal → question branch silent
        qa_text(candidate_q, "Nitrogen", None): _qa_vec(100),
    }

    def fake_embedder(query: str) -> list[float]:
        return embeds[query]

    seed_store = PgvectorQuestionStore(session_factory=factory)
    dedup_store = PgvectorQuestionStore(
        database_url=engine.url.render_as_string(hide_password=False),
        embedder=fake_embedder,
    )
    corpus_id, gap_id = uuid.uuid4(), uuid.uuid4()
    try:
        assert await seed_store.add(_make_question(corpus_id, corpus_q, embeds[corpus_q]))
        await _set_embedding_qa(factory, corpus_id, _qa_vec(100))

        candidate = _make_question(uuid.uuid4(), candidate_q, None)
        candidate.correct_answer = "Nitrogen"
        ctx = _ctx([candidate])
        stage = DedupStage(dedup_store, gold_standard_path=None, qa_embedding=True)
        result = await stage.run(ctx, _NullSink())

        assert ctx.questions == []
        assert result.info["drop_reasons"]["cosine_qa"] == 1
        assert result.info["drop_reasons"]["cosine"] == 0

        # Guard: one live row with a question embedding and no QA embedding.
        assert await seed_store.add(_make_question(gap_id, "Gap row", _vec([50])))
        ctx_gap = _ctx([_make_question(uuid.uuid4(), candidate_q, None)])
        with pytest.raises(RuntimeError, match="backfill_embedding_qa.py"):
            await stage.run(ctx_gap, _NullSink())
    finally:
        await _cleanup(factory, [corpus_id, gap_id])
