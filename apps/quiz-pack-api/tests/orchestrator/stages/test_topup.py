"""Unit tests for TopUpStage (issue #103 F5).

Why these scenarios:

- `test_no_shortfall_is_a_noop`: the common case (nothing dropped) must not
  pay for an extra generation round — asserting zero calls into the
  generation stage pins that.
- `test_backfills_shortfall_to_target`: the core contract — a pack short
  after the first pass gets topped up to `target_count` via the SAME
  generation/verification/scoring/dedup stages, not a special-cased path.
- `test_stops_at_max_rounds_above_floor`: bounded retries — a persistently
  low-yield prompt still delivers (above the floor) instead of looping
  forever or blocking on an unbounded number of LLM calls.
- `test_raises_below_floor`: the fail-loud gate — #103 F5's whole point is
  that a pack this short must NOT reach `PersistStage`/`delivered` silently.
- `test_merges_existing_before_dedup`: proves a top-up round's new batch is
  deduped against what's ALREADY accepted (not just against itself) — the
  bug this stage exists to avoid is reintroducing a near-duplicate of an
  earlier-round question.
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.stages.topup import TopUpStage
from quiz_shared.models.question import Question


def _stub_question(text: str) -> Question:
    return Question(
        id=f"q_{uuid.uuid4().hex}",
        question=text,
        correct_answer="answer",
        topic="General",
        category="general",
        difficulty="medium",
    )


def _make_ctx(target_count: int, initial: int) -> OrderContext:
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="famous capitals of the world",
        language="en",
        target_count=target_count,
    )
    ctx.questions = [_stub_question(f"initial {i}") for i in range(initial)]
    return ctx


class _RecordingSink:
    async def start_step(self, step: str, info: Any = None) -> int:
        return 0

    async def finish_step(self, step: str, event_id: int, info: Any = None) -> None:
        pass

    async def publish(self, event_id: int, step: str, progress: int, info: Any = None) -> None:
        pass


class _FakeGenStage:
    """Mirrors GenerationStage: OVERWRITES ctx.questions with `ctx.target_count`
    fresh questions (the shortfall, per TopUpStage's temporary retarget)."""

    name = "generating"

    def __init__(self) -> None:
        self.calls: list[int] = []

    async def run(self, ctx: OrderContext, sink: Any) -> StageResult:
        self.calls.append(ctx.target_count)
        ctx.questions = [
            _stub_question(f"round{len(self.calls)}-{i}")
            for i in range(ctx.target_count)
        ]
        return StageResult(info={"questions": len(ctx.questions)}, cost_cents=1)


class _FakeDropStage:
    """Mirrors Verification/ScoringStage: drops `drop_n` from the END of
    whatever is currently in ctx.questions (the new batch, at the point
    TopUpStage calls it)."""

    def __init__(self, name: str, drop_n: int) -> None:
        self.name = name
        self._drop_n = drop_n

    async def run(self, ctx: OrderContext, sink: Any) -> StageResult:
        keep = max(0, len(ctx.questions) - self._drop_n)
        ctx.questions = ctx.questions[:keep]
        return StageResult(info={"dropped": self._drop_n}, cost_cents=0)


class _PassthroughDedupStage:
    """No-op dedup — records the merged batch it saw for assertions."""

    name = "dedup"

    def __init__(self) -> None:
        self.seen_batches: list[list[Question]] = []

    async def run(self, ctx: OrderContext, sink: Any) -> StageResult:
        self.seen_batches.append(list(ctx.questions))
        return StageResult(info={"kept": len(ctx.questions), "dropped": 0}, cost_cents=0)


@pytest.mark.asyncio
async def test_no_shortfall_is_a_noop() -> None:
    """target already met after the initial pass → zero top-up rounds, zero
    extra generation calls (must not pay for LLM calls it doesn't need)."""
    gen = _FakeGenStage()
    verify = _FakeDropStage("verifying", drop_n=0)
    score = _FakeDropStage("scoring", drop_n=0)
    dedup = _PassthroughDedupStage()
    stage = TopUpStage(gen, verify, score, dedup)
    ctx = _make_ctx(target_count=10, initial=10)

    result = await stage.run(ctx, _RecordingSink())

    assert gen.calls == []
    assert len(ctx.questions) == 10
    assert result.info["topup_rounds"] == 0


@pytest.mark.asyncio
async def test_backfills_shortfall_to_target() -> None:
    """A pack short by 3 gets topped up to target_count in one round."""
    gen = _FakeGenStage()
    verify = _FakeDropStage("verifying", drop_n=0)
    score = _FakeDropStage("scoring", drop_n=0)
    dedup = _PassthroughDedupStage()
    stage = TopUpStage(gen, verify, score, dedup)
    ctx = _make_ctx(target_count=10, initial=7)

    result = await stage.run(ctx, _RecordingSink())

    assert gen.calls == [3]  # asked for exactly the shortfall
    assert len(ctx.questions) == 10
    assert result.info["topup_rounds"] == 1
    assert result.info["final_count"] == 10
    # ctx.target_count must be restored to the real target after the round.
    assert ctx.target_count == 10


@pytest.mark.asyncio
async def test_stops_at_max_rounds_above_floor() -> None:
    """Verification keeps dropping 1 of every top-up batch — after 2 rounds
    (the bounded max) the pack is still short of target_count but above the
    80% floor, so it delivers rather than looping forever."""
    gen = _FakeGenStage()
    verify = _FakeDropStage("verifying", drop_n=1)
    score = _FakeDropStage("scoring", drop_n=0)
    dedup = _PassthroughDedupStage()
    stage = TopUpStage(gen, verify, score, dedup, max_rounds=2)
    ctx = _make_ctx(target_count=10, initial=6)

    result = await stage.run(ctx, _RecordingSink())

    # Round 1: shortfall=4, verify drops 1 -> +3 (9 total).
    # Round 2: shortfall=1, verify drops 1 -> +0 (still 9 total).
    assert gen.calls == [4, 1]
    assert result.info["topup_rounds"] == 2
    assert len(ctx.questions) == 9
    assert 9 >= 0.8 * 10  # above the floor — must NOT have raised


@pytest.mark.asyncio
async def test_raises_below_floor() -> None:
    """Every top-up round's batch is wiped out entirely — the pack never
    climbs off its initial low count, which sits below the 80% floor. The
    stage must fail loud instead of letting the worker mark this 'delivered'."""
    gen = _FakeGenStage()
    verify = _FakeDropStage("verifying", drop_n=999)  # drops everything
    score = _FakeDropStage("scoring", drop_n=0)
    dedup = _PassthroughDedupStage()
    stage = TopUpStage(gen, verify, score, dedup, max_rounds=2)
    ctx = _make_ctx(target_count=10, initial=5)  # 5/10 = 50% < 80% floor

    with pytest.raises(ValueError, match="pack shortfall"):
        await stage.run(ctx, _RecordingSink())

    assert len(ctx.questions) == 5  # unchanged — no top-up batch survived


@pytest.mark.asyncio
async def test_merges_existing_before_dedup() -> None:
    """Dedup must see the FULL merged list (existing + new), not just the
    new batch — otherwise a top-up round could reintroduce a near-duplicate
    of a question an earlier round already accepted."""
    gen = _FakeGenStage()
    verify = _FakeDropStage("verifying", drop_n=0)
    score = _FakeDropStage("scoring", drop_n=0)
    dedup = _PassthroughDedupStage()
    stage = TopUpStage(gen, verify, score, dedup)
    ctx = _make_ctx(target_count=10, initial=7)

    await stage.run(ctx, _RecordingSink())

    assert len(dedup.seen_batches) == 1
    assert len(dedup.seen_batches[0]) == 10  # 7 existing + 3 new, merged
