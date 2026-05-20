"""Unit tests for SourcingStage (issue #36 task 2.4).

Each scenario captures why the contract matters:

- `test_populates_ctx_facts_with_2x_target`: dedup downstream (DedupStage,
  task 2.8) needs headroom — if we asked FactSourcer for exactly N facts,
  a near-duplicate drop rate of even 10% would leave a short pack. The 2×
  target_count multiplier is what gives dedup that headroom.
- `test_passes_category_and_theme_as_topics`: order metadata must flow
  through to the underlying source so wiki/web queries are actually
  relevant. A passing test that ignores topics would mask a regression.
- `test_tavily_call_counts_cost`: per-tier cost cap (Phase 3, #37) and the
  Phase 2 sanity ceiling (`total_cost_cents < 100`) both depend on this
  cost increment landing in `StageResult.cost_cents`.
- `test_emits_start_and_finish_through_pack_generator`: SSE clients watch
  the step name — `sourcing` MUST be the name PackGenerator records. The
  wrapper through PackGenerator is the integration the acceptance check
  cares about.
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest

from app.db.models import GenerationOrder
from app.orchestrator import OrderContext, PackGenerator
from app.orchestrator.progress_sink import ProgressSink
from app.orchestrator.stages.sourcing import TAVILY_CENTS_PER_CALL, SourcingStage
from app.sourcing.models import Fact, FactBatch


class _RecordingSink:
    """Minimal in-memory ProgressSink for stage tests."""

    def __init__(self) -> None:
        self.events: list[tuple[str, str, dict[str, Any] | None]] = []
        self._next_id = 0

    async def start_step(
        self, step: str, info: dict[str, Any] | None = None
    ) -> int:
        eid = self._next_id
        self._next_id += 1
        self.events.append(("start", step, info))
        return eid

    async def finish_step(
        self, step: str, event_id: int, info: dict[str, Any] | None = None
    ) -> None:
        self.events.append(("finish", step, info))

    async def publish(
        self,
        event_id: int,
        step: str,
        progress: int,
        info: dict[str, Any] | None = None,
    ) -> None:
        self.events.append(("publish", step, {"progress": progress, "info": info}))


class _FakeFactSourcer:
    """FactSourcer double that returns a canned FactBatch."""

    def __init__(self, batch: FactBatch) -> None:
        self.batch = batch
        self.calls: list[dict[str, Any]] = []

    async def gather_facts(
        self,
        count: int = 30,
        topics: list[str] | None = None,
        include_news: bool = True,
    ) -> FactBatch:
        self.calls.append(
            {"count": count, "topics": topics, "include_news": include_news}
        )
        return self.batch


def _make_facts(n: int, source: str = "wikipedia") -> list[Fact]:
    return [
        Fact(text=f"fact {i}", source_url=f"https://example.test/{i}", source_name=source)
        for i in range(n)
    ]


def _make_ctx(target_count: int = 10, **kwargs: Any) -> OrderContext:
    return OrderContext(
        order_id=uuid.uuid4(),
        prompt=kwargs.get("prompt", "famous capitals"),
        language=kwargs.get("language", "en"),
        target_count=target_count,
        category=kwargs.get("category"),
        theme=kwargs.get("theme"),
    )


@pytest.mark.asyncio
async def test_populates_ctx_facts_with_2x_target() -> None:
    batch = FactBatch(facts=_make_facts(20), sources_used=["wikipedia"])
    sourcer = _FakeFactSourcer(batch)
    stage = SourcingStage(sourcer)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=10)

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert len(ctx.facts) == 20
    assert sourcer.calls[0]["count"] == 20  # 2 × target_count headroom for dedup
    assert result.info["facts"] == 20


@pytest.mark.asyncio
async def test_passes_category_and_theme_as_topics() -> None:
    sourcer = _FakeFactSourcer(FactBatch(facts=_make_facts(5), sources_used=["wikipedia"]))
    stage = SourcingStage(sourcer)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=3, category="science", theme="space")

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert sourcer.calls[0]["topics"] == ["science", "space"]


@pytest.mark.asyncio
async def test_topics_is_none_when_no_category_or_theme() -> None:
    sourcer = _FakeFactSourcer(FactBatch(facts=_make_facts(5), sources_used=["wikipedia"]))
    stage = SourcingStage(sourcer)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=3, category=None, theme=None)

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert sourcer.calls[0]["topics"] is None


@pytest.mark.asyncio
async def test_tavily_call_counts_cost() -> None:
    batch = FactBatch(facts=_make_facts(5), sources_used=["wikipedia", "web_search"])
    sourcer = _FakeFactSourcer(batch)
    stage = SourcingStage(sourcer)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=3)

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert result.cost_cents == TAVILY_CENTS_PER_CALL


@pytest.mark.asyncio
async def test_no_cost_when_web_search_not_used() -> None:
    batch = FactBatch(facts=_make_facts(5), sources_used=["wikipedia", "opentdb"])
    sourcer = _FakeFactSourcer(batch)
    stage = SourcingStage(sourcer)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=3)

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert result.cost_cents == 0


@pytest.mark.asyncio
async def test_emits_start_and_finish_through_pack_generator() -> None:
    """The acceptance check: PackGenerator's wrapping makes the sink see
    start_step('sourcing') + finish_step('sourcing', ...)."""
    sourcer = _FakeFactSourcer(FactBatch(facts=_make_facts(8), sources_used=["wikipedia"]))
    stage = SourcingStage(sourcer)  # type: ignore[arg-type]
    sink = _RecordingSink()

    order = GenerationOrder(
        id=uuid.uuid4(),
        transaction_id=f"txn_{uuid.uuid4().hex}",
        product_id="pack_10",
        prompt="famous capitals",
        target_count=4,
        language="en",
        category="general",
        status="in_progress",
    )

    pack_gen = PackGenerator(stages=[stage], sink_factory=lambda _oid: sink)
    await pack_gen.run(order)

    kinds_steps = [(kind, step) for kind, step, _info in sink.events]
    assert ("start", "sourcing") in kinds_steps
    assert ("finish", "sourcing") in kinds_steps
