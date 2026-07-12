"""Unit tests for SourcingStage (issue #36 task 2.4).

Each scenario captures why the contract matters:

- `test_populates_ctx_facts_with_2x_target`: dedup downstream (DedupStage,
  task 2.8) needs headroom — if we asked FactSourcer for exactly N facts,
  a near-duplicate drop rate of even 10% would leave a short pack. The 2×
  target_count multiplier is what gives dedup that headroom.
- `test_passes_category_theme_and_prompt_tokens_as_topics`: order metadata
  AND salient prompt tokens must flow through to the underlying source so
  wiki/web queries are actually relevant (#42 task 42.28). A passing test
  that ignores those topics would mask a regression.
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
from app.orchestrator.stages.sourcing import SourcingStage
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
    """FactSourcer double matching the real `gather_facts(count, topics)`
    signature. The prior double carried a drifted `include_news` param the
    real sourcer never had — corrected as part of #42 task 42.28."""

    def __init__(self, batch: FactBatch) -> None:
        self.batch = batch
        self.calls: list[dict[str, Any]] = []

    async def gather_facts(
        self,
        count: int = 30,
        topics: list[str] | None = None,
    ) -> FactBatch:
        self.calls.append({"count": count, "topics": topics})
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
async def test_facts_emerge_surprise_ranked() -> None:
    """RC-2 (#72 P3.2): the stage must score facts with the free heuristic and
    rank them — `top_by_surprise()` had zero call sites, so the prompt's "prefer
    surprising facts" was dead. A dull OpenTDB re-wrap must sink below an extreme
    fact, and the 2× dedup headroom (count) must be preserved (ordering only)."""
    dull = Fact(
        text="The answer to 'What is the capital of France?' is Paris.",
        source_name="opentdb",
    )
    plain = Fact(text="Paris is a city in France.", source_name="wikipedia")
    extreme = Fact(
        text="The Nile is the longest river, at 6,650 km.", source_name="wikipedia"
    )
    batch = FactBatch(
        facts=[dull, plain, extreme], sources_used=["opentdb", "wikipedia"]
    )
    sourcer = _FakeFactSourcer(batch)
    stage = SourcingStage(sourcer)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=10)

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert len(ctx.facts) == 3  # ordering only — no facts dropped
    assert ctx.facts[0] is extreme  # markers + number rank it first
    assert ctx.facts[-1] is dull  # the OpenTDB re-wrap sinks to the bottom


@pytest.mark.asyncio
async def test_passes_category_theme_and_prompt_tokens_as_topics() -> None:
    """Curated metadata AND salient prompt tokens must reach the sourcer.

    #42 task 42.28: category/theme are blank on most orders, so sourcing was
    topic-agnostic and the questions drifted off-prompt. Topics now lead with
    the curated category/theme then append ≤3 stopword-filtered tokens mined
    from the prompt (no LLM). A test that ignored the prompt tokens would mask
    the very regression 42.28 fixes."""
    sourcer = _FakeFactSourcer(FactBatch(facts=_make_facts(5), sources_used=["wikipedia"]))
    stage = SourcingStage(sourcer)  # type: ignore[arg-type]
    ctx = _make_ctx(
        target_count=3,
        category="science",
        theme="space",
        prompt="ancient Roman emperors",
    )

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    # Curated metadata first, then the 3 prompt-derived tokens.
    assert sourcer.calls[0]["topics"] == [
        "science",
        "space",
        "ancient",
        "roman",
        "emperors",
    ]


@pytest.mark.asyncio
async def test_prompt_tokens_used_when_no_category_or_theme() -> None:
    """Even with no category/theme, salient prompt tokens steer sourcing —
    the common case, since most orders omit category/theme (#42 task 42.28)."""
    sourcer = _FakeFactSourcer(FactBatch(facts=_make_facts(5), sources_used=["wikipedia"]))
    stage = SourcingStage(sourcer)  # type: ignore[arg-type]
    ctx = _make_ctx(
        target_count=3,
        category=None,
        theme=None,
        prompt="ancient Roman emperors",
    )

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert sourcer.calls[0]["topics"] == ["ancient", "roman", "emperors"]


@pytest.mark.asyncio
async def test_prompt_token_dedupes_case_insensitively_and_drops_filler() -> None:
    """A prompt echoing the category must not produce a duplicate topic, and
    trivia filler ("facts") must not eat the token budget.

    #42 task 42.28 review fix: category="History" + prompt "…history…" would
    otherwise yield ["History", "history"], making Wikipedia search the same
    concept twice and re-introducing the near-duplicate facts the fact
    partition removes. Dedup is case-insensitive; "facts" is dropped as filler
    before token selection."""
    sourcer = _FakeFactSourcer(FactBatch(facts=_make_facts(5), sources_used=["wikipedia"]))
    stage = SourcingStage(sourcer)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=3, category="History", prompt="ancient history facts")

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    # "history" deduped against "History"; "facts" filtered as filler.
    assert sourcer.calls[0]["topics"] == ["History", "ancient"]


@pytest.mark.asyncio
async def test_topics_none_when_no_metadata_and_prompt_all_stopwords() -> None:
    """No category/theme and a prompt with no salient tokens → topics None,
    preserving the downstream "no topics → broad feeds" fallback."""
    sourcer = _FakeFactSourcer(FactBatch(facts=_make_facts(5), sources_used=["wikipedia"]))
    stage = SourcingStage(sourcer)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=3, category=None, theme=None, prompt="make me a quiz")

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert sourcer.calls[0]["topics"] is None


# --- #72 F-1: no-category curated topic-pool wiring ------------------------


class _StubPool:
    """A TopicPool stand-in with a fixed ``sample()`` — keeps these wiring tests
    about the stage's routing, not the pool's file I/O (covered in
    test_topic_pool.py). ``calls`` proves the stage only samples on no-signal."""

    def __init__(self, sampled: list[str] | None) -> None:
        self._sampled = sampled
        self.calls = 0

    def sample(self, count: int | None = None) -> list[str] | None:
        self.calls += 1
        return self._sampled


@pytest.mark.asyncio
async def test_pool_sampled_when_no_topic_signal() -> None:
    """The core F-1 contract: no category/theme + a generic-only prompt means
    the heuristic yields no topics, so the pool's diverse concrete sample must
    reach the sourcer (instead of "surprising facts about general") and be
    recorded on ctx for an auditable no-category run."""
    sourcer = _FakeFactSourcer(FactBatch(facts=_make_facts(5), sources_used=["wikipedia"]))
    sampled = ["deep-sea bioluminescence", "the history of coffee", "jazz"]
    pool = _StubPool(sampled)
    stage = SourcingStage(sourcer, topic_pool=pool)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=3, category=None, theme=None, prompt="general knowledge")

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert pool.calls == 1
    assert sourcer.calls[0]["topics"] == sampled
    assert ctx.auto_topics == sampled
    assert result.info["auto_topics"] == sampled


@pytest.mark.asyncio
async def test_pool_not_sampled_when_topic_signal_present() -> None:
    """A real topic must NOT touch the pool — the heuristic already steers
    sourcing, and the pool is only for the no-signal case."""
    sourcer = _FakeFactSourcer(FactBatch(facts=_make_facts(5), sources_used=["wikipedia"]))
    pool = _StubPool(["should-not-be-used"])
    stage = SourcingStage(sourcer, topic_pool=pool)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=3, category=None, theme=None, prompt="ancient Roman emperors")

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert pool.calls == 0
    assert sourcer.calls[0]["topics"] == ["ancient", "roman", "emperors"]
    assert ctx.auto_topics is None


@pytest.mark.asyncio
async def test_pool_empty_preserves_broad_feed_fallback() -> None:
    """When the pool is empty/missing (sample returns None), sourcing must keep
    today's `topics=None` broad-feed behavior — a missing pool file never
    blocks a generation run."""
    sourcer = _FakeFactSourcer(FactBatch(facts=_make_facts(5), sources_used=["wikipedia"]))
    stage = SourcingStage(sourcer, topic_pool=_StubPool(None))  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=3, category=None, theme=None, prompt="surprise me")

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert sourcer.calls[0]["topics"] is None
    assert ctx.auto_topics is None


@pytest.mark.asyncio
async def test_generic_words_collapse_so_pool_samples() -> None:
    """Proves the stopword extension — the actual cure for the military bias:
    a prompt made only of generic 'no real topic' words (general/knowledge/mixed)
    must collapse to no tokens so the curated pool — not a "surprising facts
    about general" search — supplies the topics."""
    sourcer = _FakeFactSourcer(FactBatch(facts=_make_facts(5), sources_used=["wikipedia"]))
    sampled = ["coral reefs", "renaissance art"]
    pool = _StubPool(sampled)
    stage = SourcingStage(sourcer, topic_pool=pool)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=3, category=None, theme=None, prompt="mixed general knowledge")

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert pool.calls == 1
    assert sourcer.calls[0]["topics"] == sampled


@pytest.mark.asyncio
async def test_no_pool_keeps_legacy_none_topics() -> None:
    """Dormant-by-default: with no pool injected (the worker/live path under
    Scope A), a no-signal order still resolves to None topics exactly as before
    — the live path stays byte-identical."""
    sourcer = _FakeFactSourcer(FactBatch(facts=_make_facts(5), sources_used=["wikipedia"]))
    stage = SourcingStage(sourcer)  # type: ignore[arg-type]  # no pool
    ctx = _make_ctx(target_count=3, category=None, theme=None, prompt="general knowledge")

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert sourcer.calls[0]["topics"] is None
    assert ctx.auto_topics is None


@pytest.mark.asyncio
async def test_stage_reports_no_flat_cost_estimate() -> None:
    """#95: Tavily spend is measured per actual search call in
    app.cost_tracking, so the stage must not double-count with an estimate —
    even when web_search was used."""
    batch = FactBatch(facts=_make_facts(5), sources_used=["wikipedia", "web_search"])
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
