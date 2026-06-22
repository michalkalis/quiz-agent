"""Round-trip + cosine top-match check for `PgvectorQuestionStore` (#36 task 2.19).

Verifies the shared pgvector-backed store can:
- write a `Question` via `add`,
- read it back via `get` (round-trip)
- return it as the top hit via `search(query_text=...)` (cosine via `<=>`)
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from quiz_shared.database.pgvector_client import (
    EMBEDDING_DIM,
    PgvectorQuestionStore,
)
from quiz_shared.models.question import Question


def _fixed_embedding(seed: int) -> list[float]:
    """Deterministic unit-ish vector that differs by seed for the cosine test."""
    vec = [0.0] * EMBEDDING_DIM
    # Put weight on a small handful of positions so two seeded vectors land
    # at distinct cosine distances without depending on the embedder.
    for i in range(8):
        vec[(seed * 13 + i) % EMBEDDING_DIM] = 1.0
    return vec


def _make_question(qid: uuid.UUID, text_: str, embedding: list[float]) -> Question:
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


def _vec(positions: list[int]) -> list[float]:
    """Unit-weighted vector with 1.0 at the given positions (else 0.0).

    Cosine similarity between two such vectors is ``overlap / sqrt(|a|*|b|)``,
    so overlapping-position counts give predictable, threshold-crossing scores
    without touching the OpenAI embedder.
    """
    vec = [0.0] * EMBEDDING_DIM
    for p in positions:
        vec[p] = 1.0
    return vec


@pytest.mark.asyncio
async def test_find_duplicates_threshold_and_self(engine: AsyncEngine) -> None:
    """`find_duplicates` flags near-paraphrases (>= 0.85), rejects weak/unrelated
    matches, and still returns the query's own row (self-exclusion is the
    caller's job — `DedupStage` filters by id, which is why this method must
    NOT)."""
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

    # 8-position base vector for the stored "capital of France" question.
    base = [0, 1, 2, 3, 4, 5, 6, 7]
    # Query vectors mapped by text so the cosine ranking is deterministic:
    #   paraphrase: 7/8 overlap -> cos ~0.935  (a real near-duplicate)
    #   weak:       2/8 overlap -> cos ~0.50   (related-but-distinct, < 0.85)
    #   self:       exact base  -> cos 1.0      (the query's own row)
    query_vecs = {
        "paraphrase": _vec(base[:7]),
        "weak": _vec(base[:2]),
        "self": _vec(base),
    }

    def fake_embedder(query: str) -> list[float]:
        return query_vecs[query]

    store = PgvectorQuestionStore(session_factory=factory, embedder=fake_embedder)

    target_id = uuid.uuid4()
    other_id = uuid.uuid4()
    target = _make_question(target_id, "Capital of France?", _vec(base))
    # Unrelated question on disjoint positions -> cosine 0 against every query.
    other = _make_question(other_id, "Famous painters?", _vec([200, 201, 202, 203]))

    try:
        assert await store.add(target) is True
        assert await store.add(other) is True

        # Near-paraphrase: target is a duplicate (>= 0.85); the unrelated
        # question is not returned at all.
        dups = await store.find_duplicates("paraphrase", threshold=0.85)
        scored = {q.id: score for q, score in dups}
        assert str(target_id) in scored, "near-paraphrase should flag the target"
        assert scored[str(target_id)] >= 0.85
        assert str(other_id) not in scored, "unrelated question must not match"
        # Returned items are (Question, float) tuples.
        q0, score0 = dups[0]
        assert isinstance(q0, Question)
        assert isinstance(score0, float)

        # Weak overlap stays below the gate -> no duplicates.
        weak = await store.find_duplicates("weak", threshold=0.85)
        assert weak == [], "a 0.5-similarity match must not cross the 0.85 gate"

        # Self-match: the store returns the query's own row by design; the id
        # filter that keeps a re-run idempotent lives in DedupStage, not here.
        self_dups = await store.find_duplicates("self", threshold=0.85)
        assert str(target_id) in {q.id for q, _ in self_dups}
    finally:
        async with factory() as session:
            await session.execute(
                text("DELETE FROM questions WHERE id IN (:a, :b)"),
                {"a": target_id, "b": other_id},
            )
            await session.commit()


@pytest.mark.asyncio
async def test_round_trip_and_cosine_top_match(engine: AsyncEngine) -> None:
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

    # Test-private embedder: maps known prompts to fixed vectors so the
    # cosine ranking is deterministic and doesn't hit the OpenAI API.
    seen_seeds = {"capital of france": 1, "famous painters": 2}

    def fake_embedder(query: str) -> list[float]:
        seed = seen_seeds.get(query.lower(), 99)
        return _fixed_embedding(seed)

    store = PgvectorQuestionStore(session_factory=factory, embedder=fake_embedder)

    target_id = uuid.uuid4()
    other_id = uuid.uuid4()
    target = _make_question(
        target_id, "What is the capital of France?", _fixed_embedding(1)
    )
    other = _make_question(other_id, "Name two famous painters.", _fixed_embedding(2))

    try:
        assert await store.add(target) is True
        assert await store.add(other) is True

        # Round-trip: get the target by id.
        fetched = await store.get(str(target_id))
        assert fetched is not None
        assert fetched.id == str(target_id)
        assert fetched.question == target.question
        assert fetched.embedding is not None
        assert len(fetched.embedding) == EMBEDDING_DIM

        # Cosine top-match: query close to target's embedding should rank it first.
        results = await store.search(
            query_text="capital of france",
            filters={"review_status": "approved"},
            n_results=5,
        )
        assert results, "expected at least one match"
        assert results[0].id == str(target_id), (
            f"top match was {results[0].id}, expected {target_id}"
        )
    finally:
        async with factory() as session:
            await session.execute(
                text("DELETE FROM questions WHERE id IN (:a, :b)"),
                {"a": target_id, "b": other_id},
            )
            await session.commit()
