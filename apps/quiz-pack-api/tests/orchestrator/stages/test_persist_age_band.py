"""#236 — a pack ordered for a child band stamps the band on its questions.

Why: `questions.age_band` is how every later reader knows a row was written for
a child (the live retriever keeps banded rows out of the ordinary quiz, the
section serves them by band). A child pack's rows are already isolated by their
`pack_id`, but if they were persisted unstamped, the band would be lost the
moment one is reused, shared or reviewed outside its pack. An adult or legacy
order (audience None / "adults") must stamp nothing, or its questions would
vanish from places that serve ordinary questions. Both persist paths are
covered: the single-shot `run` and the incremental `persist_batch`.
"""

from __future__ import annotations

import pytest
from app.audience import LIMITS
from app.db.models import QuestionRow
from app.orchestrator.stages.persist import PersistStage
from quiz_shared.models.question import AGE_BANDS
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from tests.orchestrator.stages.test_persist import (  # noqa: F401
    _alembic_head,
    _cleanup_order,
    _make_ctx,
    _make_order,
    _RecordingSink,
    _stub_question,
    engine,
    session,
    session_factory,
)


def test_question_bands_are_the_order_child_audiences() -> None:
    """The order's child `audience` is what gets stamped as `age_band`, and the
    retriever matches `age_band` by exact string: a band spelt differently in
    the two places would make a stamped row unreachable by its own section."""
    assert set(AGE_BANDS) == set(LIMITS)


async def _bands(db: AsyncSession, pack_id) -> list:
    rows = await db.execute(
        select(QuestionRow.age_band).where(QuestionRow.pack_id == pack_id)
    )
    return [r[0] for r in rows]


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("audience", "expected"),
    [("kids_7_9", "kids_7_9"), ("adults", None), (None, None)],
)
async def test_run_stamps_only_a_child_band(
    session: AsyncSession,  # noqa: F811
    session_factory: async_sessionmaker[AsyncSession],  # noqa: F811
    audience,
    expected,
) -> None:
    order = await _make_order(session, target_count=2)
    ctx = _make_ctx(order, [_stub_question(i) for i in range(2)])
    ctx.audience = audience

    await PersistStage(session_factory).run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert await _bands(session, ctx.pack_id) == [expected, expected]
    await _cleanup_order(session, order.id)


@pytest.mark.asyncio
async def test_persist_batch_stamps_every_batch_of_a_child_pack(
    session: AsyncSession,  # noqa: F811
    session_factory: async_sessionmaker[AsyncSession],  # noqa: F811
) -> None:
    order = await _make_order(session, target_count=3)
    ctx = _make_ctx(order, [])
    ctx.audience = "kids_4_6"
    stage = PersistStage(session_factory)

    await stage.persist_batch(ctx, [_stub_question(0), _stub_question(1)])
    await stage.persist_batch(ctx, [_stub_question(2)])

    assert await _bands(session, ctx.pack_id) == ["kids_4_6"] * 3
    await _cleanup_order(session, order.id)
