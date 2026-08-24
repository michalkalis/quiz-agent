"""Unit tests for `PackGenerator.run` loop (issue #36 task 2.3).

These tests exercise the orchestrator loop with Stage doubles and an
in-memory ProgressSink — no DB, no Redis, no LLM. Why each scenario:

- `test_runs_stages_in_order`: the loop's defining contract is sequential
  execution, so the test pins stage ordering by name.
- `test_accumulates_cost_cents`: per-tier cost cap (Phase 3) and the
  Phase 2 sanity ceiling (`total_cost_cents < 100`) both rely on this
  accumulation being correct.
- `test_exception_in_stage_skips_later_stages`: subsequent stages MUST
  NOT run after a failure — otherwise a downstream `PersistStage` could
  persist half-baked output produced by a partially-failed pipeline.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Any

import pytest

from app.db.models import GenerationOrder
from app.orchestrator import OrderContext, PackGenerator, StageResult
from app.orchestrator.progress_sink import ProgressSink


# ── Test doubles ──────────────────────────────────────────────────────────────


class RecordingSink:
    """In-memory ProgressSink that captures every call for assertions."""

    def __init__(self) -> None:
        self.events: list[tuple[str, str, dict[str, Any] | None]] = []
        self._next_id = 0

    async def start_step(
        self, step: str, info: dict[str, Any] | None = None
    ) -> int:
        event_id = self._next_id
        self._next_id += 1
        self.events.append(("start", step, info))
        return event_id

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


@dataclass
class FakeStage:
    name: str
    cost_cents: int = 0
    raises: Exception | None = None
    ran: bool = False

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        self.ran = True
        if self.raises is not None:
            raise self.raises
        return StageResult(info={"stage": self.name}, cost_cents=self.cost_cents)


def _make_order() -> GenerationOrder:
    """In-memory GenerationOrder — not persisted, but PackGenerator only reads attrs."""
    return GenerationOrder(
        id=uuid.uuid4(),
        transaction_id=f"txn_{uuid.uuid4().hex}",
        product_id="pack_10",
        prompt="famous capitals",
        target_count=3,
        language="en",
        category="general",
        status="in_progress",
    )


# ── Tests ─────────────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_runs_stages_in_order() -> None:
    s1, s2, s3 = FakeStage("sourcing"), FakeStage("generating"), FakeStage("verifying")
    sink = RecordingSink()

    gen = PackGenerator(stages=[s1, s2, s3], sink_factory=lambda _oid: sink)
    pack = await gen.run(_make_order())

    assert pack is None  # No PersistStage → no pack
    assert (s1.ran, s2.ran, s3.ran) == (True, True, True)

    # Sequence the sink saw: start → finish → publish, three times in order.
    starts = [step for kind, step, _ in sink.events if kind == "start"]
    assert starts == ["sourcing", "generating", "verifying"]

    # Progress climbs monotonically and lands at 100 on the last stage.
    publish_events = [info["progress"] for kind, _, info in sink.events if kind == "publish"]
    assert publish_events == sorted(publish_events)
    assert publish_events[-1] == 100


@pytest.mark.asyncio
async def test_accumulates_cost_cents() -> None:
    """`ctx.cost_cents` must sum across stages — the Phase 2 cost-cap guardrail depends on it."""

    captured: dict[str, OrderContext] = {}

    class CaptureStage:
        name = "capture"

        async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
            captured["ctx"] = ctx
            return StageResult(cost_cents=0)

    stages = [
        FakeStage("sourcing", cost_cents=10),
        FakeStage("b", cost_cents=25),
        FakeStage("c", cost_cents=7),
        CaptureStage(),
    ]
    gen = PackGenerator(stages=stages, sink_factory=lambda _oid: RecordingSink())
    await gen.run(_make_order())

    assert captured["ctx"].cost_cents == 10 + 25 + 7


@pytest.mark.asyncio
async def test_exception_in_stage_skips_later_stages() -> None:
    s1 = FakeStage("sourcing", cost_cents=5)
    boom = FakeStage("generating", raises=RuntimeError("LLM exploded"))
    s3 = FakeStage("verifying")

    sink = RecordingSink()
    gen = PackGenerator(stages=[s1, boom, s3], sink_factory=lambda _oid: sink)

    with pytest.raises(RuntimeError, match="LLM exploded"):
        await gen.run(_make_order())

    # s1 ran, boom ran (and raised), s3 did NOT run.
    assert s1.ran is True
    assert boom.ran is True
    assert s3.ran is False

    # A `failed` step must have been opened on the sink with error=repr(exc) —
    # matches the Phase 1 stub's `_handle_failure` shape so SSE clients see
    # the same event format whether the failure came from the stub or a stage.
    failed_starts = [
        info for kind, step, info in sink.events
        if kind == "start" and step == "failed"
    ]
    assert len(failed_starts) == 1
    assert "LLM exploded" in failed_starts[0]["error"]


@pytest.mark.asyncio
async def test_requires_sourcing_first() -> None:
    """F8 source-quality gate (#36 task 2.15): every PackGenerator must
    start with a sourcing stage so persisted questions inherit a real
    `source_url` rather than letting the LLM hallucinate one. The
    constructor rejects a stage list that omits sourcing or places it
    elsewhere — failing loud at wiring time, not at runtime.
    """
    sink_factory = lambda _oid: RecordingSink()  # noqa: E731

    # Empty list → rejected.
    with pytest.raises(ValueError, match="sourcing"):
        PackGenerator(stages=[], sink_factory=sink_factory)

    # First stage isn't sourcing → rejected.
    with pytest.raises(ValueError, match="sourcing"):
        PackGenerator(
            stages=[FakeStage("generating"), FakeStage("sourcing")],
            sink_factory=sink_factory,
        )

    # First stage is sourcing → constructs fine.
    PackGenerator(
        stages=[FakeStage("sourcing"), FakeStage("generating")],
        sink_factory=sink_factory,
    )


@pytest.mark.asyncio
async def test_hanging_stage_fails_with_timeout(monkeypatch) -> None:
    """#139 acceptance 1: a stage that hangs (stalled LLM connection) must
    become a caught, logged TimeoutError — not an ARQ job_timeout kill with
    zero diagnostics, which is how the 2026-08-03 order died silently."""
    import asyncio

    from app.orchestrator import pack_generator as pg_module

    monkeypatch.setattr(pg_module, "_STAGE_TIMEOUT_SECONDS", 0.05)

    class HangingStage:
        name = "generating"

        async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
            await asyncio.sleep(60)
            return StageResult()

    s1 = FakeStage("sourcing")
    s3 = FakeStage("verifying")
    sink = RecordingSink()
    gen = PackGenerator(
        stages=[s1, HangingStage(), s3], sink_factory=lambda _oid: sink
    )

    with pytest.raises(TimeoutError, match="generating"):
        await gen.run(_make_order())

    assert s3.ran is False
    # The worker's cancellation handler names the hung stage from here.
    assert gen.current_stage == "generating"
    failed_starts = [
        info for kind, step, info in sink.events
        if kind == "start" and step == "failed"
    ]
    assert len(failed_starts) == 1
    assert "STAGE_TIMEOUT_SECONDS" in failed_starts[0]["error"]


# --- #166 D21b — direct generation is the server-side default -----------------


@pytest.mark.asyncio
async def test_direct_generation_default_on(monkeypatch) -> None:
    """#166 (founder 2026-08-24): with nothing set, every order runs direct —
    SourcingStage skips fact gathering and the generator's direct v1 prompt
    carries the batch. The lever stays server-side (#157: customer text can
    never set it)."""
    monkeypatch.delenv("DIRECT_GENERATION", raising=False)
    stage = FakeStage("sourcing")
    gen = PackGenerator(stages=[stage], sink_factory=lambda _oid: RecordingSink())

    await gen.run(_make_order())

    assert gen.last_ctx is not None
    assert gen.last_ctx.direct_generation is True


@pytest.mark.asyncio
async def test_direct_generation_env_rollback(monkeypatch) -> None:
    """DIRECT_GENERATION=0 restores the grounded sourcing + fact-first flow;
    an order whose server-side generation_mode column says "direct" stays
    direct regardless (#157 still the only per-order lever)."""
    monkeypatch.setenv("DIRECT_GENERATION", "0")
    stage = FakeStage("sourcing")
    gen = PackGenerator(stages=[stage], sink_factory=lambda _oid: RecordingSink())

    await gen.run(_make_order())
    assert gen.last_ctx is not None
    assert gen.last_ctx.direct_generation is False

    direct_order = _make_order()
    direct_order.generation_mode = "direct"
    await gen.run(direct_order)
    assert gen.last_ctx.direct_generation is True
