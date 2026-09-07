"""#170 D6 answer cap against a live pgvector store (task 170.9, A6/A14).

Why this matters: the unit tests prove the stage's arithmetic with a canned
counter; this one proves the REAL counter's scope — corpus rows only
(`pack_id IS NULL`), live review states only (approved + pending_review),
legacy NULL language folded into 'en' — and that DedupStage wired to it
lets exactly `cap` rows through per category. A customer-pack row carrying
the same answer must never move the count (locked 3, A14).

Needs TEST_DATABASE_URL at migration a170c0e5d1b2 (`answer_key` column).
"""

from __future__ import annotations

import os
import subprocess
import sys
import uuid
from pathlib import Path

import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.db.engine import build_engine, normalize_async_url
from app.db.models import GenerationOrder, QuestionPack, QuestionRow
from app.orchestrator import OrderContext
from app.orchestrator.stages.dedup import DedupStage, _normalize_answer
from app.orchestrator.stages.strictness import Strictness, parse_strictness
from quiz_shared.database.pgvector_client import PgvectorQuestionStore
from quiz_shared.models.question import Question

APP_ROOT = Path(__file__).resolve().parents[2]
TAG = "170-answer-cap-test"


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
        async with eng.begin() as conn:
            await conn.execute(text("DELETE FROM questions WHERE topic = :t"), {"t": TAG})
        yield eng
        async with eng.begin() as conn:
            await conn.execute(text("DELETE FROM questions WHERE topic = :t"), {"t": TAG})
    finally:
        await eng.dispose()


class _NullSink:
    async def start_step(self, step, info=None):
        return 0

    async def finish_step(self, *a, **k):
        return None

    async def publish(self, *a, **k):
        return None


def _row(answer: str, **overrides) -> QuestionRow:
    data = {
        "id": uuid.uuid4(),
        "question": f"{TAG} {uuid.uuid4().hex[:6]}",
        "type": "text",
        "correct_answer": answer,
        "answer_key": _normalize_answer(answer),
        "topic": TAG,
        "category": "geography-world",
        "difficulty": "easy",
        "language": "en",
        "review_status": "approved",
    }
    data.update(overrides)
    return QuestionRow(**data)


async def _seed(engine: AsyncEngine) -> None:
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with factory() as session:
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
        session.add_all(
            [
                _row("Paris"),  # live, counts
                _row("Paris", language=None),  # legacy NULL language → 'en', counts
                _row("Paris", review_status="archived"),  # not live, ignored
                _row("Paris", pack_id=pack.id),  # customer pack, ignored (locked 3)
                _row("Paris", category="history"),  # other category, ignored
            ]
        )
        await session.commit()


def _candidate(idx: int, answer: str = "Paris") -> Question:
    return Question(
        id=str(uuid.uuid4()),
        question=f"{TAG} candidate {idx}",
        type="text",
        correct_answer=answer,
        topic=TAG,
        category="geography-world",
        difficulty="easy",
        language="en",
    )


@pytest.mark.asyncio
async def test_counter_scope_is_live_corpus_rows_only(engine: AsyncEngine) -> None:
    await _seed(engine)
    store = PgvectorQuestionStore(
        database_url=engine.url.render_as_string(hide_password=False)
    )
    key = _normalize_answer("Paris")
    assert await store.count_answer_key("en", "geography-world", key) == 2
    assert await store.count_answer_key("en", "history", key) == 1
    assert await store.count_answer_key("sk", "geography-world", key) == 0


@pytest.mark.asyncio
async def test_dedupstage_with_live_counter_lets_exactly_cap_rows_through(
    engine: AsyncEngine,
) -> None:
    await _seed(engine)  # 2 live 'paris' rows in geography-world
    store = PgvectorQuestionStore(
        database_url=engine.url.render_as_string(hide_password=False),
        embedder=lambda _text: None,
    )

    class _NoCosine:
        async def find_duplicates(self, question_text, threshold=0.85):
            return []

    stage = DedupStage(
        _NoCosine(),
        None,
        strictness=Strictness(
            profiles=parse_strictness("geography-world=cap:4"), answer_cap=True
        ),
        answer_counter=store,
    )
    ctx = OrderContext(order_id=uuid.uuid4(), prompt=TAG, language="en", target_count=3)
    ctx.questions = [_candidate(0), _candidate(1), _candidate(2)]
    result = await stage.run(ctx, sink=_NullSink())
    # cap 4 with 2 already live → 2 more pass, the third drops as answer_cap
    assert result.info["kept"] == 2
    assert result.info["answer_cap"] == 1
    assert result.info["drop_reasons"]["cosine"] == 0
