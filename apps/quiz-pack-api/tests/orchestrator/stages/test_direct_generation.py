"""Direct-generation mode tests (#153 Phase 0.4).

The founder's "reverse flow": generate unconstrained by web-found facts,
verify at the end of the pipe. The mode is an OrderContext bool carried by a
prompt marker (no order column — same mechanism as ``mcq_emphasis``).

- `test_sourcing_short_circuits_in_direct_mode`: SourcingStage must gather
  NOTHING (no Tavily/Wikipedia spend) and say so in its info — a direct arm
  that silently sourced facts would invalidate the facts-vs-direct
  comparison the mode exists for.
- `test_marker_sets_context_flag`: the prompt marker is the only transport
  for the flag; if PackGenerator stops translating it, the mode silently
  degrades to the fact-sourced path.
- `test_cli_direct_flag_appends_marker`: the CLI lever must actually emit
  the marker.
"""

from __future__ import annotations

import uuid

import pytest

from app.orchestrator.context import DIRECT_GENERATION_MARKER, OrderContext
from app.orchestrator.stages.sourcing import SourcingStage

import scripts.generate_pack as generate_pack


class _ExplodingSourcer:
    async def gather_facts(self, *args, **kwargs):
        raise AssertionError("direct mode must not gather facts")


class _NullSink:
    async def start_step(self, step, info=None):
        return 0

    async def finish_step(self, step, event_id, info=None):
        pass

    async def publish(self, event_id, step, progress, info=None):
        pass


@pytest.mark.asyncio
async def test_sourcing_short_circuits_in_direct_mode():
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="anything",
        language="en",
        target_count=10,
        direct_generation=True,
    )
    ctx.facts = ["stale"]

    result = await SourcingStage(_ExplodingSourcer()).run(ctx, _NullSink())

    assert ctx.facts == []
    assert result.info == {"direct_generation": True, "facts": 0}


@pytest.mark.asyncio
async def test_marker_sets_context_flag():
    from app.db.models import GenerationOrder
    from app.orchestrator import PackGenerator
    from app.orchestrator.context import StageResult

    seen: dict[str, bool] = {}

    class _RecordingSourcing:
        name = "sourcing"

        async def run(self, ctx, sink):
            seen["direct"] = ctx.direct_generation
            return StageResult(cost_cents=0)

    order = GenerationOrder(
        id=uuid.uuid4(),
        transaction_id="txn_direct_marker",
        product_id="pack_10",
        prompt=f"surprising facts\n\n{DIRECT_GENERATION_MARKER}",
        target_count=10,
        language="en",
        status="in_progress",
    )
    generator = PackGenerator(
        stages=[_RecordingSourcing()], sink_factory=lambda _oid: _NullSink()
    )
    await generator.run(order)

    assert seen == {"direct": True}


def test_cli_direct_flag_appends_marker():
    args = generate_pack._parse_args(
        ["--prompt", "space oddities", "--direct", "--dry-run"]
    )
    order = generate_pack._build_order(args)
    assert DIRECT_GENERATION_MARKER in order.prompt

    plain = generate_pack._parse_args(["--prompt", "space oddities", "--dry-run"])
    assert DIRECT_GENERATION_MARKER not in generate_pack._build_order(plain).prompt
