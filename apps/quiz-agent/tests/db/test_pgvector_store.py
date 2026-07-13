"""PgvectorQuestionStore write surface — upsert / delete / get_all (#41 A2).

Why these tests matter: #41 D3 moves the admin endpoints (import, delete,
list, stats) and the feedback writes off ChromaDB onto this store. The new
methods must match the old `ChromaDBQuestionStore` write semantics exactly:

- `upsert` is add-or-replace by id and never silently no-ops on an existing
  id — a no-oping upsert would make admin edits and review-status flips
  vanish without error.
- `delete` is idempotent — the old admin delete succeeded on absent ids.
- `get_all` backs the admin list endpoint (full-collection iteration).

Runs against the dev-stack Postgres (`TEST_DATABASE_URL`, colima #73); the
`questions` table is alembic-managed by quiz-pack-api and persistent, so all
assertions are scoped to ids created here and cleaned up in `finally`.
"""

from __future__ import annotations

import os
import uuid
from datetime import datetime, timezone

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.db.engine import build_engine
from quiz_shared.database.pgvector_client import EMBEDDING_DIM, PgvectorQuestionStore
from quiz_shared.database.sync_pgvector_store import SyncPgvectorStore
from quiz_shared.models.question import Question


def _test_db_url() -> str | None:
    return os.environ.get("TEST_DATABASE_URL")


def _make_question(qid: uuid.UUID, text_: str, **overrides) -> Question:
    fields = dict(
        id=str(qid),
        question=text_,
        type="text",
        correct_answer="Paris",
        topic="Geography",
        category="general",
        difficulty="easy",
        review_status="approved",
        source="generated",
        # Embedding carried on the Question so the store never calls OpenAI.
        embedding=[1.0] + [0.0] * (EMBEDDING_DIM - 1),
        embedding_model="test-fixture",
        embedding_dim=EMBEDDING_DIM,
        created_at=datetime.now(timezone.utc),
    )
    fields.update(overrides)
    return Question(**fields)


@pytest_asyncio.fixture
async def pg_store():
    """(store, session_factory) on the test Postgres; engine disposed after."""
    url = _test_db_url()
    if not url:
        pytest.skip("TEST_DATABASE_URL not set — skipping DB-backed test")
    engine = build_engine(url)
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    try:
        yield PgvectorQuestionStore(session_factory=factory), factory
    finally:
        await engine.dispose()


async def _cleanup(factory, ids: list[uuid.UUID]) -> None:
    async with factory() as session:
        await session.execute(
            text("DELETE FROM questions WHERE id = ANY(:ids)"), {"ids": ids}
        )
        await session.commit()


@pytest.mark.asyncio
async def test_upsert_inserts_then_replaces_by_id(pg_store) -> None:
    """Upsert = add-or-replace. The second upsert on the same id must
    overwrite fields (here: the admin/feedback-written `review_status` and the
    question text), not no-op — otherwise review flips silently vanish."""
    store, factory = pg_store
    qid = uuid.uuid4()
    try:
        assert await store.upsert(_make_question(qid, "Capital of France?")) is True
        first = await store.get(str(qid))
        assert first is not None and first.review_status == "approved"

        updated = _make_question(
            qid,
            "What city is the capital of France?",
            review_status="rejected",
            difficulty="hard",
        )
        assert await store.upsert(updated) is True

        after = await store.get(str(qid))
        assert after is not None
        assert after.question == "What city is the capital of France?"
        assert after.review_status == "rejected"
        assert after.difficulty == "hard"
        # Still exactly one row for the id — replace, not duplicate.
        async with factory() as session:
            n = await session.execute(
                text("SELECT count(*) FROM questions WHERE id = :id"), {"id": qid}
            )
            assert n.scalar_one() == 1
    finally:
        await _cleanup(factory, [qid])


@pytest.mark.asyncio
async def test_delete_removes_row_and_is_idempotent(pg_store) -> None:
    """Delete by id removes the row; deleting an absent or non-UUID id is a
    successful no-op — the old Chroma-backed admin delete was idempotent and
    the ported admin endpoint relies on the same contract."""
    store, factory = pg_store
    qid = uuid.uuid4()
    try:
        assert await store.upsert(_make_question(qid, "Capital of Slovakia?")) is True
        assert await store.delete(str(qid)) is True
        assert await store.get(str(qid)) is None
        # Idempotent re-delete + non-UUID id (cannot exist in this store).
        assert await store.delete(str(qid)) is True
        assert await store.delete("not-a-uuid") is True
    finally:
        await _cleanup(factory, [qid])


@pytest.mark.asyncio
async def test_get_all_returns_rows_and_honours_limit(pg_store) -> None:
    """get_all backs the admin list endpoint: it must surface every stored
    question (scoped here to our ids — the test DB is persistent) and cap the
    result at `limit` so the endpoint can paginate."""
    store, factory = pg_store
    ids = [uuid.uuid4() for _ in range(3)]
    try:
        for i, qid in enumerate(ids):
            assert await store.upsert(_make_question(qid, f"Q {i}: capital?")) is True

        all_rows = await store.get_all(limit=100_000)
        returned_ids = {q.id for q in all_rows}
        assert {str(i) for i in ids} <= returned_ids

        capped = await store.get_all(limit=2)
        assert len(capped) == 2  # table holds ≥3 rows (just inserted)
    finally:
        await _cleanup(factory, ids)


async def _seed_pack(factory) -> tuple[uuid.UUID, uuid.UUID]:
    """Insert the minimal generation_orders + question_packs parents a question's
    ``pack_id`` FK requires. Returns (pack_id, order_id); delete the order to
    cascade the pack away."""
    order_id, pack_id = uuid.uuid4(), uuid.uuid4()
    async with factory() as session:
        await session.execute(
            text(
                "INSERT INTO generation_orders "
                "(id, transaction_id, product_id, prompt, target_count, language) "
                "VALUES (:oid, :txn, 'pack_30', 'packtest', 30, 'en')"
            ),
            {"oid": order_id, "txn": f"admin-packtest-{uuid.uuid4().hex[:10]}"},
        )
        await session.execute(
            text(
                "INSERT INTO question_packs "
                "(id, order_id, prompt, language, target_count) "
                "VALUES (:pid, :oid, 'packtest', 'en', 30)"
            ),
            {"pid": pack_id, "oid": order_id},
        )
        await session.commit()
    return pack_id, order_id


async def _cleanup_orders(factory, order_ids: list[uuid.UUID]) -> None:
    async with factory() as session:
        # ON DELETE CASCADE removes the pack; questions.pack_id is SET NULL.
        await session.execute(
            text("DELETE FROM generation_orders WHERE id = ANY(:ids)"),
            {"ids": order_ids},
        )
        await session.commit()


@pytest.mark.asyncio
async def test_search_pack_id_filter_isolates_pack_and_excludes_null(pg_store) -> None:
    """#95: the retriever scopes a custom-pack session on ``pack_id`` and a
    normal session on ``pack_id IS NULL``. This pins the real SQL both ways
    against Postgres/asyncpg — a str pack_id must bind against the UUID column
    (the ``_build_where`` coercion), equality must isolate one pack from
    another, and the IS NULL branch must still exclude pack rows even when every
    other field matches (the private-pack leak guard). A unique category scopes
    the assertions away from the persistent shared corpus."""
    store, factory = pg_store
    cat = f"__packtest_{uuid.uuid4().hex[:8]}__"
    pack_a, order_a = await _seed_pack(factory)
    pack_b, order_b = await _seed_pack(factory)
    q_a, q_b, q_global = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    try:
        await store.upsert(
            _make_question(q_a, "Pack A question?", category=cat, pack_id=str(pack_a))
        )
        await store.upsert(
            _make_question(q_b, "Pack B question?", category=cat, pack_id=str(pack_b))
        )
        await store.upsert(
            _make_question(q_global, "Global question?", category=cat, pack_id=None)
        )

        # Pack scoping: a *string* pack_id binds against the UUID column and
        # returns ONLY that pack's row — not pack B, not the global row.
        a_rows = await store.search(
            filters={"pack_id": str(pack_a), "category": cat}, n_results=100
        )
        assert {q.id for q in a_rows} == {str(q_a)}

        # Normal session (IS NULL): excludes BOTH pack rows despite the shared
        # category — the exclusion is the pack filter, not incidental.
        null_rows = await store.search(
            filters={"pack_id": None, "category": cat}, n_results=100
        )
        assert {q.id for q in null_rows} == {str(q_global)}

        # Sanity: with no pack filter, all three rows share the category.
        all_rows = await store.search(filters={"category": cat}, n_results=100)
        assert {str(q_a), str(q_b), str(q_global)} <= {q.id for q in all_rows}
    finally:
        await _cleanup(factory, [q_a, q_b, q_global])
        await _cleanup_orders(factory, [order_a, order_b])


def test_sync_facade_write_roundtrip() -> None:
    """SyncPgvectorStore is the surface quiz-agent's sync consumers (admin,
    feedback) will actually call after Session B — the new writes must work
    through the background-loop bridge, not just on the async store."""
    url = _test_db_url()
    if not url:
        pytest.skip("TEST_DATABASE_URL not set — skipping DB-backed test")

    # The sync bridge owns its engine (created on its background loop) —
    # never share a test-loop-bound engine across loops.
    store = SyncPgvectorStore(PgvectorQuestionStore(database_url=url))
    qid = uuid.uuid4()
    try:
        assert store.upsert(_make_question(qid, "Sync: capital of Italy?")) is True
        fetched = store.get(str(qid))
        assert fetched is not None and fetched.question == "Sync: capital of Italy?"
        assert str(qid) in {q.id for q in store.get_all(limit=100_000)}
    finally:
        assert store.delete(str(qid)) is True
        assert store.get(str(qid)) is None
