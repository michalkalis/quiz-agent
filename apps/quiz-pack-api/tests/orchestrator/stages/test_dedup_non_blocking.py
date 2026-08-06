"""DedupStage must not block the worker event loop (#150).

Dedup used to reach pgvector through `SyncPgvectorStore`, a
`future.result()` bridge: for the whole embedding + query round trip the
worker thread was parked, so nothing else on the loop ran. That made every
hang-protection layer #139 added inert *on this one stage* — the 60s job
heartbeat could not tick (and a stale `updated_at` lets the sweep re-enqueue
a still-running paid order → a second pipeline for one purchase), and both
`asyncio.wait_for` belts are cancellation-based, which cannot reach a blocked
thread.

The two tests below encode exactly those two consequences:

- `test_heartbeat_keeps_ticking_during_slow_dedup_store_call`: a
  heartbeat-style task must keep ticking while a slow store call is in
  flight, and the slow store's verdict must still be honoured (it returns a
  real duplicate that has to be dropped). A regression to a sync call would
  hand the stage a coroutine object instead of matches, which the stage's
  own `except Exception` would swallow into "not a duplicate".
- `test_hung_dedup_store_fails_loud_with_named_stage`: a store that never
  returns must now be *cancellable*, so `PackGenerator`'s per-stage belt
  fires, names the stage and fails the order instead of freezing the worker.
"""

from __future__ import annotations

import asyncio
import uuid
from typing import Any

import pytest

from app.db.models import GenerationOrder
from app.orchestrator import OrderContext, PackGenerator
from app.orchestrator import pack_generator as pack_generator_module
from app.orchestrator.context import StageResult
from app.orchestrator.stages.dedup import DedupStage
from quiz_shared.models.question import Question


class _NullSink:
    def __init__(self) -> None:
        self.events: list[tuple[str, str, Any]] = []

    async def start_step(self, step: str, info: Any = None) -> int:
        self.events.append(("start", step, info))
        return 0

    async def finish_step(self, step: str, event_id: int, info: Any = None) -> None:
        self.events.append(("finish", step, info))

    async def publish(
        self, event_id: int, step: str, progress: int, info: Any = None
    ) -> None:
        self.events.append(("publish", step, info))


class _SourcingStub:
    """PackGenerator refuses a stage list that does not start with sourcing."""

    name = "sourcing"

    async def run(self, ctx: OrderContext, sink: Any) -> StageResult:
        return StageResult(cost_cents=0)


def _stub_question(idx: int, text: str) -> Question:
    return Question(
        id=f"q_{idx}",
        question=text,
        correct_answer="answer",
        topic="General",
        category="general",
        difficulty="medium",
    )


def _make_ctx(questions: list[Question]) -> OrderContext:
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="famous capitals",
        language="en",
        target_count=len(questions),
    )
    ctx.questions = list(questions)
    return ctx


def _make_order() -> GenerationOrder:
    return GenerationOrder(
        id=uuid.uuid4(),
        transaction_id=f"txn_{uuid.uuid4().hex}",
        product_id="pack_10",
        prompt="famous capitals",
        target_count=1,
        language="en",
        category="general",
        status="in_progress",
    )


@pytest.mark.asyncio
async def test_heartbeat_keeps_ticking_during_slow_dedup_store_call() -> None:
    existing = _stub_question(99, "What is the capital of France?")

    class _SlowStore:
        async def find_duplicates(
            self, question_text: str, threshold: float = 0.85
        ) -> list[tuple[Question, float]]:
            await asyncio.sleep(0.2)
            return [(existing, 0.95)]

    ticks = 0

    async def _heartbeat() -> None:
        nonlocal ticks
        while True:
            await asyncio.sleep(0.01)
            ticks += 1

    heartbeat = asyncio.create_task(_heartbeat())
    ctx = _make_ctx([_stub_question(0, "Which city is France's capital?")])
    try:
        result = await DedupStage(_SlowStore(), gold_standard_path=None).run(
            ctx, _NullSink()
        )
    finally:
        heartbeat.cancel()

    # The loop stayed live for the whole ~200ms store call (a blocked thread
    # would have delivered zero ticks).
    assert ticks >= 5, f"worker loop starved during dedup: only {ticks} tick(s)"
    # ...and the awaited verdict still landed: the near-duplicate was dropped.
    assert result.info == {"kept": 0, "dropped": 1}
    assert ctx.questions == []


@pytest.mark.asyncio
async def test_hung_dedup_store_fails_loud_with_named_stage(monkeypatch) -> None:
    monkeypatch.setattr(pack_generator_module, "_STAGE_TIMEOUT_SECONDS", 0.2)

    class _HungStore:
        async def find_duplicates(
            self, question_text: str, threshold: float = 0.85
        ) -> list[tuple[Question, float]]:
            await asyncio.Event().wait()  # never returns
            raise AssertionError("unreachable")

    class _SeedingSourcing(_SourcingStub):
        async def run(self, ctx: OrderContext, sink: Any) -> StageResult:
            ctx.questions = [_stub_question(0, "What is the capital of France?")]
            return StageResult(cost_cents=0)

    sink = _NullSink()
    generator = PackGenerator(
        stages=[
            _SeedingSourcing(),
            DedupStage(_HungStore(), gold_standard_path=None),
        ],
        sink_factory=lambda _oid: sink,
    )

    with pytest.raises(TimeoutError) as excinfo:
        await asyncio.wait_for(generator.run(_make_order()), timeout=5)

    # Bounded, and it names WHERE the order died — the pre-#150 blocking
    # bridge could not be cancelled, so this belt never fired on dedup.
    assert "dedup" in str(excinfo.value)
    failed = [info for _kind, step, info in sink.events if step == "failed"]
    assert failed and "dedup" in str(failed[0])
