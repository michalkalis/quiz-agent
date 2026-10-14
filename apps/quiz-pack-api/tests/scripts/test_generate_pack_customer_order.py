"""#203 203.9 — ``generate_pack.py --customer-order``.

The founder's blind round compares custom packs generated from the CLI, with
no production database. That only measures what customers get if the CLI
builds the order the way the worker does: the customer flag on GenerationStage
(so sub-themes are planned), and the #182 round walk (1, 2, 4, 8, ...) whose
rounds go to memory on ``--dry-run``. Without the flag every corpus run must
stay as it was: nothing planned, the plain single-pass walk.

The built walk runs for real; only its LLM-backed edges (generator, planner,
verification, scoring) are swapped for fakes, and the dedup store embeds
nothing remote.
"""

from __future__ import annotations

import asyncio
import uuid

import pytest
from app.orchestrator.context import OrderContext
from app.orchestrator.offline_stages import InMemoryPackStage
from app.orchestrator.stages import TopUpStage

from scripts import generate_pack
from tests.orchestrator.stages.test_pack_subthemes import (
    SUBTHEMES,
    _Generator,
    _Planner,
    _Store,
)
from tests.orchestrator.stages.test_topup import _CountingSink, _FakeDropStage


def _built_walk(argv: list[str]) -> TopUpStage:
    args = generate_pack._parse_args(["--prompt", "Harry Potter", *argv])
    stages = generate_pack._build_stages(
        persist=not args.dry_run,
        dedup_store=_Store(),
        customer_order=args.customer_order,
    )
    return next(s for s in stages if isinstance(s, TopUpStage))


@pytest.mark.parametrize("customer_order", [True, False])
async def test_customer_order_flag_plans_subthemes_on_the_worker_walk(
    monkeypatch: pytest.MonkeyPatch, customer_order: bool
) -> None:
    monkeypatch.setenv("PACK_SUBTHEMES", "1")
    monkeypatch.setenv("TAVILY_API_KEY", "tvly-test-placeholder")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test-placeholder")
    monkeypatch.delenv("PACK_BATCH_SCHEDULE", raising=False)
    argv = ["--dry-run"] + (["--customer-order"] if customer_order else [])
    topup = _built_walk(argv)

    gen, planner = _Generator(), _Planner()
    topup._generation_stage._generator = gen
    topup._generation_stage._subtheme_planner = planner
    topup._verification_stage = _FakeDropStage("verifying", 0)
    topup._scoring_stage = _FakeDropStage("scoring", 0)
    topup._answerability_stage = None
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt="Harry Potter",
        language="en",
        target_count=30,
        theme="Harry Potter",
        direct_generation=True,
    )
    if not customer_order:
        # The corpus walk runs one full-size pass before TopUpStage.
        await topup._generation_stage.run(ctx, _CountingSink())

    await asyncio.wait_for(topup.run(ctx, _CountingSink()), timeout=5)

    if customer_order:
        # Dry run: the worker's rounds, written nowhere.
        assert isinstance(topup._persist_stage, InMemoryPackStage)
        assert planner.calls == [("Harry Potter", "en", 9)]
        assert [c["count"] for c in gen.calls[:2]] == [1, 2]
        assert gen.calls[1]["topics"][0] in SUBTHEMES
    else:
        assert topup._persist_stage is None
        assert planner.calls == []
        assert all(c["topics"] == ["Harry Potter"] for c in gen.calls)
    assert len(ctx.questions) == 30
