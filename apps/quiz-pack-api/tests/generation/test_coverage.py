"""`app/generation/coverage.py` — the coverage map allocator (#170 task 170.12).

Why these tests matter:
- Steering is only worth doing if it is **reproducible**: the same seed and
  the same corpus must yield the same cell and the same avoid-list, or the
  A/B quality guard (170.15) compares two different experiments.
- The empty-corpus case must be uniform *by construction* (D3). If K ever
  stopped absorbing the "no rows yet" case, a fresh corpus would be steered
  by noise.
- A deep cell must lose share, not be banned — locked 2 (a duplicate is not
  a tragedy), so the weight has to decay smoothly.
- The B2 rule is the one that protects quality: a category whose rows carry
  no subtopic means the backfill has not run. Degrading to uniform there
  would look like it worked while steering blind.
- The avoid-list is trimmed to 10 *inside the module* because
  `prompt_builder.py` hard-cuts at 10; an untrimmed, unordered list would
  send an arbitrary 10 of N into the prompt.

The live-DB legs (bottom) prove the query scope: `pack_id IS NOT NULL` rows
are invisible to both the counts and the avoid-list (A14, locked 3). They
need TEST_DATABASE_URL and are skipped otherwise.
"""

from __future__ import annotations

import os
import subprocess
import sys
import uuid
from collections import Counter
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
import pytest_asyncio
from app.db.engine import build_engine, normalize_async_url
from app.db.models import GenerationOrder, QuestionPack, QuestionRow
from app.generation.coverage import (
    AVOID_LIMIT,
    CoverageAllocator,
    CoverageUnavailableError,
    PgvectorCoverageSource,
)
from app.generation.subtopics import subtopics_for
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

APP_ROOT = Path(__file__).resolve().parents[2]
CATEGORY = "geography-world"
CELLS = subtopics_for(CATEGORY)
TAG = "170-coverage-test"


class _FakeSource:
    """Counts and cell questions without a database — the arithmetic is the
    unit under test, the SQL is covered by the live legs below."""

    def __init__(
        self,
        counts: dict[str | None, int],
        questions: dict[str, list[str]] | None = None,
    ) -> None:
        self.counts = counts
        self.questions = questions or {}

    async def cell_counts(self, language: str, category: str) -> dict[str | None, int]:
        return dict(self.counts)

    async def recent_questions(
        self, language: str, category: str, subtopic: str, limit: int
    ) -> list[str]:
        return list(self.questions.get(subtopic, []))[:limit]


def _allocator(counts, questions=None) -> CoverageAllocator:
    return CoverageAllocator(_FakeSource(counts, questions))


async def _draw(allocator: CoverageAllocator, seeds: range) -> list[str]:
    return [(await allocator.allocate("en", CATEGORY, s)).subtopic for s in seeds]


@pytest.mark.asyncio
async def test_same_seed_and_counts_give_the_same_cells() -> None:
    """Reproducibility: the A/B guard replays a run by seed, so identical
    input must give an identical cell sequence — not merely a similar one."""
    counts = {cell: i % 5 for i, cell in enumerate(CELLS)}
    first = await _draw(_allocator(counts), range(20))
    second = await _draw(_allocator(counts), range(20))
    assert first == second
    # And the seed actually moves the draw (a constant allocator would also
    # pass the equality above).
    assert len(set(first)) > 1


@pytest.mark.asyncio
async def test_empty_corpus_is_uniform_by_construction() -> None:
    """D3: with every count 0, K collapses to 1 and all weights are equal —
    a fresh corpus must not be steered by anything."""
    allocator = _allocator({})
    draws = Counter(await _draw(allocator, range(4000)))
    expected = 4000 / len(CELLS)
    # Chi-square-free check: no cell may deviate more than ~4 sigma of a
    # uniform multinomial (sigma ~= sqrt(expected)) — a real bias (e.g. a
    # forgotten weight) shifts cells by multiples of that.
    tolerance = 4 * expected**0.5
    assert draws.keys() <= set(CELLS)
    for cell in CELLS:
        assert abs(draws[cell] - expected) < tolerance, cell


@pytest.mark.asyncio
async def test_a_cell_far_above_k_loses_share() -> None:
    """Locked 2: an over-covered cell is throttled, not banned — its share
    must fall well below uniform while staying reachable."""
    hot = CELLS[0]
    counts = {cell: 5 for cell in CELLS}
    counts[hot] = 500  # K ~= 5*len(CELLS)/len(CELLS) rounded up by the hot cell
    draws = Counter(await _draw(_allocator(counts), range(3000)))
    uniform_share = 3000 / len(CELLS)
    assert draws[hot] < uniform_share / 2
    assert draws[CELLS[1]] > uniform_share / 2


@pytest.mark.asyncio
async def test_category_without_subtopic_tagged_rows_fails_loud() -> None:
    """B2: live rows but no subtopic anywhere = the backfill has not run.
    Steering uniformly there would silently fake coverage knowledge."""
    with pytest.raises(CoverageUnavailableError, match="subtopic backfill|none"):
        await _allocator({None: 81}).allocate("en", CATEGORY, 1)


@pytest.mark.asyncio
async def test_untagged_rows_alongside_tagged_ones_do_not_fail() -> None:
    """A half-backfilled category still steers: the untagged rows only raise
    K (a flatter, more cautious distribution), they are not an error."""
    allocation = await _allocator({None: 50, CELLS[0]: 3}).allocate("en", CATEGORY, 1)
    assert allocation.subtopic in CELLS


@pytest.mark.asyncio
async def test_unknown_category_raises() -> None:
    """The taxonomy is the source of truth (A1): an unknown category must not
    fall back to a made-up cell list."""
    with pytest.raises(KeyError):
        await _allocator({}).allocate("en", "not-a-category", 1)


@pytest.mark.asyncio
async def test_avoid_list_is_stable_and_capped_at_ten() -> None:
    """`prompt_builder.py` hard-cuts the avoid slot at 10 — the module must
    do the cut itself, over a fixed order, or the prompt gets an arbitrary
    10 of N and two identical runs steer differently."""
    counts = {cell: 3 for cell in CELLS}
    questions = {cell: [f"q{i}" for i in range(25)] for cell in CELLS}
    allocator = _allocator(counts, questions)

    first = await allocator.allocate("en", CATEGORY, 7)
    second = await allocator.allocate("en", CATEGORY, 7)
    assert first.subtopic == second.subtopic
    assert first.avoid_questions == second.avoid_questions
    assert len(first.avoid_questions) == AVOID_LIMIT
    assert first.avoid_questions == tuple(f"q{i}" for i in range(AVOID_LIMIT))


@pytest.mark.asyncio
async def test_allocation_carries_the_cell_key() -> None:
    """Session I writes the allocated cell at persist (D4) — language and
    category must travel with the subtopic, not be re-derived downstream."""
    allocation = await _allocator({CELLS[0]: 1}).allocate("en", CATEGORY, 3)
    assert (allocation.language, allocation.category) == ("en", CATEGORY)


# ── Live-DB legs: query scope (A14, locked 3) ────────────────────────────────


def _raw_url() -> str:
    url = os.environ.get("TEST_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not url:
        pytest.skip("TEST_DATABASE_URL / DATABASE_URL not set")
    return url


@pytest.fixture(scope="module")
def _alembic_head() -> None:
    # Not autouse on purpose: the pure-Python legs above must run without a
    # database, so only the live-DB `engine` fixture pulls the migration in.
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
async def engine(_alembic_head) -> AsyncEngine:
    eng = build_engine(normalize_async_url(_raw_url()))
    try:
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


def _row(question: str, created_at: datetime, **overrides) -> QuestionRow:
    data = {
        "id": uuid.uuid4(),
        "question": question,
        "type": "text",
        "correct_answer": "Paris",
        "topic": TAG,
        "category": CATEGORY,
        "difficulty": "easy",
        "language": "en",
        "review_status": "approved",
        "subtopic": CELLS[0],
        "created_at": created_at,
    }
    data.update(overrides)
    return QuestionRow(**data)


async def _seed(engine: AsyncEngine) -> None:
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    now = datetime.now(UTC)
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
        pack = QuestionPack(
            order_id=order.id, prompt=TAG, language="en", target_count=1
        )
        session.add(pack)
        await session.flush()
        session.add_all(
            [
                _row(f"{TAG} live newest", now),
                _row(f"{TAG} live older", now - timedelta(days=1)),
                # legacy NULL language folds into 'en' (D2)
                _row(f"{TAG} legacy lang", now - timedelta(days=2), language=None),
                # not live → invisible
                _row(f"{TAG} archived", now, review_status="archived"),
                # customer pack → invisible (locked 3 / A14)
                _row(f"{TAG} pack row", now, pack_id=pack.id),
                # another cell of the same category
                _row(f"{TAG} other cell", now, subtopic=CELLS[1]),
                # untagged corpus row: counted under None, never a cell
                _row(f"{TAG} untagged", now, subtopic=None),
            ]
        )
        await session.commit()


@pytest.mark.asyncio
async def test_counts_see_live_corpus_rows_only(engine: AsyncEngine) -> None:
    """The map must be built from the playable corpus: a customer-pack row or
    an archived row shifting a weight would steer generation by data the
    corpus does not own (locked 3, A14)."""
    await _seed(engine)
    source = PgvectorCoverageSource(engine.url.render_as_string(hide_password=False))
    counts = await source.cell_counts("en", CATEGORY)
    assert counts.get(CELLS[0]) == 3  # 2 live + 1 legacy NULL language
    assert counts.get(CELLS[1]) == 1
    assert counts.get(None) == 1  # untagged row visible as "backfill gap"
    assert sum(counts.values()) == 5  # archived + pack row excluded


@pytest.mark.asyncio
async def test_avoid_list_is_newest_first_and_excludes_pack_rows(
    engine: AsyncEngine,
) -> None:
    """The avoid slot must carry the freshest questions of the cell and never
    a customer-pack question — that would leak pack content into the corpus
    prompt (locked 3) and waste the 10 slots on rows dedup never checks."""
    await _seed(engine)
    source = PgvectorCoverageSource(engine.url.render_as_string(hide_password=False))
    avoid = await source.recent_questions("en", CATEGORY, CELLS[0], AVOID_LIMIT)
    assert avoid == [
        f"{TAG} live newest",
        f"{TAG} live older",
        f"{TAG} legacy lang",
    ]
    assert not any("pack row" in q or "archived" in q for q in avoid)


@pytest.mark.asyncio
async def test_allocator_over_live_source_runs_the_d9_explain(
    engine: AsyncEngine, caplog
) -> None:
    """D9: the coverage query gets the same planner tripwire as the dedup
    query, so nobody has to remember to look. Today's plan must not be an
    ivfflat index scan; the day it is, the warning is the signal."""
    import logging

    await _seed(engine)
    source = PgvectorCoverageSource(engine.url.render_as_string(hide_password=False))
    with caplog.at_level(logging.INFO):
        allocation = await CoverageAllocator(source).allocate("en", CATEGORY, 11)
    assert allocation.subtopic in CELLS
    assert len(allocation.avoid_questions) <= AVOID_LIMIT
    assert any("D9 check" in r.getMessage() for r in caplog.records)
