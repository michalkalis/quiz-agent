"""Direct-generation mode tests (#153 Phase 0.4, reworked by #157/D4).

The founder's "reverse flow": generate unconstrained by web-found facts,
verify at the end of the pipe. Since #157 the mode is activated ONLY by the
server-side ``GenerationOrder.generation_mode`` column — the old in-prompt
marker was a confirmed hole (customer order text could switch off sourcing +
grounding checks on its own paid pack) and is now inert.

- `test_sourcing_short_circuits_in_direct_mode`: SourcingStage must gather
  NOTHING (no Tavily/Wikipedia spend) and say so in its info — a direct arm
  that silently sourced facts would invalidate the facts-vs-direct
  comparison the mode exists for.
- `test_generation_mode_column_sets_context_flag`: the order column is the
  only transport for the flag.
- `test_marker_in_customer_prompt_is_inert_and_logged`: the D4 hole stays
  closed — marker text in a customer prompt must not activate direct mode,
  and the attempt must be visible in logs.
- `test_cli_direct_flag_sets_generation_mode`: the CLI lever sets the column,
  not prompt text.
"""

from __future__ import annotations

import logging
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


def _order(prompt: str, generation_mode: str | None = None):
    from app.db.models import GenerationOrder

    return GenerationOrder(
        id=uuid.uuid4(),
        transaction_id=f"txn_{uuid.uuid4().hex[:8]}",
        product_id="pack_10",
        prompt=prompt,
        target_count=10,
        language="en",
        status="in_progress",
        generation_mode=generation_mode,
    )


class _RecordingSourcing:
    name = "sourcing"

    def __init__(self, seen: dict):
        self._seen = seen

    async def run(self, ctx, sink):
        from app.orchestrator.context import StageResult

        self._seen["direct"] = ctx.direct_generation
        return StageResult(cost_cents=0)


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
async def test_generation_mode_column_sets_context_flag():
    from app.orchestrator import PackGenerator

    seen: dict[str, bool] = {}
    generator = PackGenerator(
        stages=[_RecordingSourcing(seen)], sink_factory=lambda _oid: _NullSink()
    )
    await generator.run(_order("surprising facts", generation_mode="direct"))

    assert seen == {"direct": True}


@pytest.mark.asyncio
async def test_marker_in_customer_prompt_is_inert_and_logged(caplog, monkeypatch):
    from app.orchestrator import PackGenerator

    # #166 made direct the server-side DEFAULT; pin the grounded flow so this
    # test still proves the #157 point — customer prompt text alone can never
    # flip the mode.
    monkeypatch.setenv("DIRECT_GENERATION", "0")

    seen: dict[str, bool] = {}
    generator = PackGenerator(
        stages=[_RecordingSourcing(seen)], sink_factory=lambda _oid: _NullSink()
    )
    with caplog.at_level(logging.WARNING):
        await generator.run(
            _order(f"surprising facts\n\n{DIRECT_GENERATION_MARKER}")
        )

    assert seen == {"direct": False}
    assert any(
        "DIRECT GENERATION MODE marker" in rec.getMessage()
        for rec in caplog.records
    )


def test_cli_direct_flag_sets_generation_mode():
    args = generate_pack._parse_args(
        ["--prompt", "space oddities", "--direct", "--dry-run"]
    )
    order = generate_pack._build_order(args)
    assert order.generation_mode == "direct"
    assert DIRECT_GENERATION_MARKER not in order.prompt

    plain = generate_pack._parse_args(["--prompt", "space oddities", "--dry-run"])
    assert generate_pack._build_order(plain).generation_mode is None
