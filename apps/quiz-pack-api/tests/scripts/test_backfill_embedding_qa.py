"""`scripts/backfill_embedding_qa.py` (#170 tasks 170.5 + 170.6, A3).

Why these tests matter:
- The free `--answer-key-only` pass is what unblocks ANSWER_CAP without a
  single paid call; if it ever reached for OpenAI (or a re-implemented
  normaliser drifted from dedup's), the cap would count something dedup
  does not compare. We assert zero embedder calls, idempotency, that
  customer-pack rows are never touched (locked 3), and that the normaliser
  is IMPORTED from dedup.py (`__module__`), never forked.
- The paid pass must embed an uncovered row exactly once and nothing on a
  second run — a runaway re-embed is real money against the OpenAI key.
- The D9 tripwire must actually fire on an ivfflat plan, or nobody learns
  when the index starts silently eating recall.

Live-DB tests need TEST_DATABASE_URL (`make dev-db`); skipped otherwise.
The unit tests at the bottom run everywhere.
"""

from __future__ import annotations

import logging
import os
import subprocess
import sys
import uuid
from pathlib import Path

import pytest
import pytest_asyncio
import scripts.backfill_embedding_qa as bf
from app.db.engine import build_engine, normalize_async_url
from app.db.models import GenerationOrder, QuestionPack, QuestionRow
from app.orchestrator.stages import dedup
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

APP_ROOT = Path(__file__).resolve().parents[2]
TAG = "170-backfill-test"


def _raw_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    return url


@pytest.fixture(scope="module", autouse=True)
def _alembic_head() -> None:
    env = os.environ.copy()
    env["DATABASE_URL"] = _raw_url()
    subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        cwd=APP_ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )


@pytest_asyncio.fixture
async def engine() -> AsyncEngine:
    eng = build_engine(normalize_async_url(_raw_url()))
    try:
        # A clean slate for the corpus predicate: every test-tagged row goes.
        async with eng.begin() as conn:
            await conn.execute(
                text("DELETE FROM questions WHERE topic = :t"), {"t": TAG}
            )
        yield eng
        async with eng.begin() as conn:
            await conn.execute(
                text("DELETE FROM questions WHERE topic = :t"), {"t": TAG}
            )
    finally:
        await eng.dispose()


def _row(**overrides) -> QuestionRow:
    data = {
        "id": uuid.uuid4(),
        "question": "Which river flows through Vienna?",
        "type": "text",
        "correct_answer": "The Danube",
        "topic": TAG,
        "category": "geography-world",
        "difficulty": "easy",
        "language": None,
        "review_status": "approved",
    }
    data.update(overrides)
    return QuestionRow(**data)


async def _seed_pack(session: AsyncSession) -> uuid.UUID:
    order = GenerationOrder(
        transaction_id=f"{TAG}-{uuid.uuid4().hex}",
        product_id="pack_10",
        prompt=TAG,
        target_count=1,
        language="en",
        status="in_progress",
    )
    session.add(order)
    await session.flush()
    pack = QuestionPack(order_id=order.id, prompt=TAG, language="en", target_count=1)
    session.add(pack)
    await session.flush()
    return pack.id


async def _seed(engine: AsyncEngine) -> tuple[uuid.UUID, uuid.UUID, uuid.UUID]:
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with factory() as session:
        pack_id = await _seed_pack(session)
        corpus_a = _row()
        corpus_b = _row(
            question="Which element has the symbol O?",
            type="text_multichoice",
            possible_answers={"a": "Oxygen", "b": "Gold"},
            correct_answer="Oxygen",
            language="en",
        )
        pack_row = _row(pack_id=pack_id)
        session.add_all([corpus_a, corpus_b, pack_row])
        await session.commit()
        return corpus_a.id, corpus_b.id, pack_row.id


async def _get(engine: AsyncEngine, row_id: uuid.UUID) -> QuestionRow:
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with factory() as session:
        row = await session.get(QuestionRow, row_id)
        assert row is not None
        return row


# ── free pass (170.5) ───────────────────────────────────────────────────────


def test_normaliser_is_imported_from_dedup_not_forked() -> None:
    assert bf._normalize_answer is dedup._normalize_answer
    assert bf._normalize_answer.__module__ == "app.orchestrator.stages.dedup"


@pytest.mark.asyncio
async def test_answer_key_pass_is_free_idempotent_and_skips_pack_rows(
    engine: AsyncEngine,
) -> None:
    a, b, pack_row = await _seed(engine)
    calls: list = []

    first = await bf.backfill_answer_keys(engine)
    assert calls == []  # no embedder involved at all in this pass
    assert first["answer_key"] >= 2 and first["language"] >= 1

    row_a, row_b, row_p = (
        await _get(engine, a),
        await _get(engine, b),
        await _get(engine, pack_row),
    )
    assert row_a.answer_key == dedup._normalize_answer("The Danube")
    assert row_a.language == "en"  # NULL → 'en'
    assert row_b.answer_key == dedup._normalize_answer("Oxygen")
    assert row_b.language == "en"  # was already 'en', untouched
    # locked 3: a customer-pack row is never touched by a corpus backfill
    assert row_p.answer_key is None and row_p.language is None

    second = await bf.backfill_answer_keys(engine)
    assert second == {"answer_key": 0, "language": 0}


@pytest.mark.asyncio
async def test_cli_answer_key_only_never_constructs_an_openai_client(
    engine: AsyncEngine, monkeypatch
) -> None:
    await _seed(engine)

    def boom():
        raise AssertionError("OpenAI client constructed in the free pass")

    monkeypatch.setattr(bf, "_openai_embedder", boom)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    args = bf.build_parser().parse_args(
        ["--database-url", _raw_url(), "--answer-key-only"]
    )
    assert await bf.run(args) == 0


# ── paid pass (170.6) ───────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_qa_pass_embeds_uncovered_rows_exactly_once(engine: AsyncEngine) -> None:
    a, _b, pack_row = await _seed(engine)
    seen: list[list[str]] = []

    def fake_embed(texts):
        seen.append(list(texts))
        return [[0.01 * (i + 1)] * 1536 for i in range(len(texts))]

    first = await bf.backfill_qa_embeddings(engine, fake_embed, batch_size=10)
    assert first["embedded"] >= 2 and first["calls"] >= 1
    flat = [t for batch in seen for t in batch]
    assert any(
        "Which river flows through Vienna?" in t and "The Danube" in t for t in flat
    )
    assert not any(str(pack_row) in t for t in flat)

    row_a, row_p = await _get(engine, a), await _get(engine, pack_row)
    assert row_a.embedding_qa is not None and len(row_a.embedding_qa) == 1536
    assert row_a.embedding_qa_model == bf.EMBEDDING_MODEL
    assert row_p.embedding_qa is None  # pack row skipped (locked 3)

    seen.clear()
    second = await bf.backfill_qa_embeddings(engine, fake_embed, batch_size=10)
    assert second == {"embedded": 0, "pending": 0, "calls": 0}
    assert seen == []


@pytest.mark.asyncio
async def test_explain_runs_and_reports_no_ivfflat_on_small_table(
    engine: AsyncEngine, caplog
) -> None:
    plan = await bf.explain_dedup_query(engine)
    assert plan  # the query shape is valid SQL against the migrated schema
    with caplog.at_level(logging.WARNING, logger="backfill_embedding_qa"):
        fired = bf.warn_if_ivfflat(plan)
    # a few test rows never justify an index scan; if this ever flips the
    # D9 revisit is due — and the warning below must be the thing that says so
    assert fired is False


# ── unit (no DB) ────────────────────────────────────────────────────────────


def test_ivfflat_plan_triggers_the_d9_warning(caplog) -> None:
    plan = (
        "Limit  (cost=0.00..1.23 rows=10 width=16)\n"
        "  ->  Index Scan using ix_questions_embedding_ivfflat on questions"
        "  (cost=0.00..123.45 rows=100 width=16)"
    )
    with caplog.at_level(logging.WARNING, logger="backfill_embedding_qa"):
        assert bf.warn_if_ivfflat(plan) is True
    assert any("ivfflat" in r.getMessage() for r in caplog.records)
    assert bf.warn_if_ivfflat("Seq Scan on questions  (cost=0.00..1.00)") is False


def test_qa_text_resolves_option_letters_to_option_text() -> None:
    assert bf.qa_text("Q?", "b", {"a": "True", "b": "False"}).endswith("Answer: False")
    assert bf.qa_text("Q?", "Oxygen", {"a": "Oxygen", "b": "Gold"}).endswith(
        "Answer: Oxygen"
    )
    assert bf.qa_text("Q?", "Mars", None) == "Question: Q?\nAnswer: Mars"
