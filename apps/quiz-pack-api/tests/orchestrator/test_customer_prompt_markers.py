"""Customer order text is player data, never a pipeline switch.

The order form lets a player type anything. Typed into a paid order, the
MULTIPLE-CHOICE EMPHASIS marker used to flip the pack into the mostly-MCQ
quota meant for CLI ``--mcq-bias`` runs — the same hole #157 closed for direct
mode. CLI orders must keep the lever, or ``--mcq-bias`` silently stops biting.
"""

from __future__ import annotations

import uuid

import pytest

from app.db.models import GenerationOrder
from app.generation.pattern_routing import MCQ_EMPHASIS_MARKER
from app.orchestrator import PackGenerator
from app.orchestrator.context import CLI_PRODUCT_ID, StageResult


class _Recording:
    name = "sourcing"

    def __init__(self, seen: dict):
        self._seen = seen

    async def run(self, ctx, sink):
        self._seen["mcq_emphasis"] = ctx.mcq_emphasis
        return StageResult(cost_cents=0)


class _NullSink:
    async def start_step(self, step, info=None):
        return 0

    async def finish_step(self, step, event_id, info=None):
        pass

    async def publish(self, event_id, step, progress, info=None):
        pass


async def _mcq_emphasis_for(product_id: str) -> bool:
    seen: dict[str, bool] = {}
    order = GenerationOrder(
        id=uuid.uuid4(),
        transaction_id=f"txn_{uuid.uuid4().hex[:8]}",
        product_id=product_id,
        prompt=f"Roman emperors\n\n{MCQ_EMPHASIS_MARKER}: all multiple choice",
        target_count=10,
        language="en",
    )
    generator = PackGenerator(
        stages=[_Recording(seen)], sink_factory=lambda _oid: _NullSink()
    )
    await generator.run(order)
    return seen["mcq_emphasis"]


@pytest.mark.asyncio
async def test_marker_in_customer_order_text_is_inert() -> None:
    assert await _mcq_emphasis_for("pack_10") is False


@pytest.mark.asyncio
async def test_marker_on_cli_order_still_sets_mcq_emphasis() -> None:
    assert await _mcq_emphasis_for(CLI_PRODUCT_ID) is True
