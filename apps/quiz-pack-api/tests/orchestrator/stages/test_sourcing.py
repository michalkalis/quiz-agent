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
    test_topic_pool.py). ``calls`` proves the stage only samples on no-signal;
    ``last_count``/``last_exclude`` let #153 tests pin what the stage asked
    for (topic-count scaling, empty-topic resample exclusion) without a real
    pool's random sampling."""

    def __init__(self, sampled: list[str] | None) -> None:
        self._sampled = sampled
        self.calls = 0
        self.last_count: int | None = None
        self.last_exclude: set[str] | None = None

    def sample(
        self, count: int | None = None, exclude: set[str] | None = None
    ) -> list[str] | None:
        self.calls += 1
        self.last_count = count
        self.last_exclude = exclude
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


# --- #153 Phase 0.2: fail-loud sourcing + empty-topic resample -------------


class _ScriptedFactSourcer:
    """FactSourcer double returning one scripted `FactBatch` per call, in
    order — lets a test drive the multi-call resample flow (the initial
    combined-topics call, then a per-topic replacement call) deterministically."""

    def __init__(self, batches: list[FactBatch]) -> None:
        self._batches = list(batches)
        self.calls: list[dict[str, Any]] = []

    async def gather_facts(
        self, count: int = 30, topics: list[str] | None = None
    ) -> FactBatch:
        self.calls.append({"count": count, "topics": topics})
        return self._batches.pop(0)


@pytest.mark.asyncio
async def test_resamples_empty_topic_from_pool() -> None:
    """The core Phase 0.2 contract: a topic that sourced 0 facts gets a
    pool-drawn replacement sourced and merged in, and is NOT reported as
    empty once the replacement succeeds."""
    initial_batch = FactBatch(
        facts=_make_facts(4, source="wikipedia"),
        sources_used=["wikipedia"],
        facts_per_topic={"volcanoes": 4, "empty topic": 0},
    )
    replacement_batch = FactBatch(
        facts=_make_facts(2, source="wikipedia"), sources_used=["wikipedia"]
    )
    sourcer = _ScriptedFactSourcer([initial_batch, replacement_batch])
    pool = _StubPool(["fresh topic"])
    stage = SourcingStage(sourcer, topic_pool=pool)  # type: ignore[arg-type]
    # All-stopword prompt so derived topics are exactly [category, theme].
    ctx = _make_ctx(
        target_count=3, category="volcanoes", theme="empty topic", prompt="make me a quiz"
    )

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert sourcer.calls[1]["topics"] == ["fresh topic"]
    assert result.info["empty_topics"] == []
    assert result.info["resampled_topics"] == 1
    assert result.info["facts_per_topic"]["fresh topic"] == 2
    assert len(ctx.facts) == 6  # original 4 facts + the 2 resampled


@pytest.mark.asyncio
async def test_empty_topic_reported_when_no_pool_wired() -> None:
    """Worker path (no TopicPool): an empty topic can't be resampled, so it
    must be logged and surfaced on `StageResult.info`, never silently
    dropped."""
    batch = FactBatch(
        facts=_make_facts(4, source="wikipedia"),
        sources_used=["wikipedia"],
        facts_per_topic={"volcanoes": 4, "empty topic": 0},
    )
    sourcer = _ScriptedFactSourcer([batch])
    stage = SourcingStage(sourcer)  # type: ignore[arg-type]  # no pool
    ctx = _make_ctx(
        target_count=3, category="volcanoes", theme="empty topic", prompt="make me a quiz"
    )

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert result.info["empty_topics"] == ["empty topic"]
    assert result.info["resampled_topics"] == 0
    assert len(sourcer.calls) == 1  # no resample call attempted


@pytest.mark.asyncio
async def test_resample_budget_exhausted_leaves_topic_empty() -> None:
    """The replacement budget is shared across the whole run (<= the
    original topic count) — once it's spent, a still-empty topic is reported
    rather than retried indefinitely."""
    initial_batch = FactBatch(
        facts=_make_facts(2, source="wikipedia"),
        sources_used=["wikipedia"],
        facts_per_topic={"topic a": 0, "topic b": 0},
    )
    empty_replacement = FactBatch(facts=[], sources_used=["wikipedia"])
    sourcer = _ScriptedFactSourcer([initial_batch, empty_replacement, empty_replacement])
    pool = _StubPool(["replacement"])  # every draw is a still-empty replacement
    stage = SourcingStage(sourcer, topic_pool=pool)  # type: ignore[arg-type]
    # prompt="make me a quiz" is all-stopword (per test_topics_none_when_no_
    # metadata_and_prompt_all_stopwords) so derived topics are EXACTLY
    # [category, theme] — otherwise mined prompt tokens would inflate the
    # budget (len(topics)) past the 2 this test pins.
    ctx = _make_ctx(
        target_count=3, category="topic a", theme="topic b", prompt="make me a quiz"
    )

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    # Budget = 2 (original topic count); both attempts are spent on
    # "topic a", so "topic b" never even gets a resample try.
    assert result.info["empty_topics"] == ["topic a", "topic b"]
    assert result.info["resampled_topics"] == 0
    assert len(sourcer.calls) == 3  # initial + the 2 budgeted replacement tries


@pytest.mark.asyncio
async def test_facts_per_topic_always_present_when_no_topics_tracked() -> None:
    """`facts_per_topic` must always be a key on `StageResult.info`, even when
    the sourcer double didn't populate it (e.g. every pre-#153 test double)."""
    sourcer = _FakeFactSourcer(FactBatch(facts=_make_facts(5), sources_used=["wikipedia"]))
    stage = SourcingStage(sourcer)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=3)

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert result.info["facts_per_topic"] == {}
    assert result.info["empty_topics"] == []
    assert result.info["resampled_topics"] == 0
    assert result.info["low_credibility_dropped"] == 0


@pytest.mark.asyncio
async def test_low_credibility_dropped_reported_in_info() -> None:
    """#153 Phase 0.3: the starvation-guarded drop count must reach
    telemetry so a batch's listicle-source rate is auditable."""
    topic = "Volcanoes"
    trustworthy = [
        Fact(text=f"Trustworthy {i}", topic=topic, credibility="medium") for i in range(3)
    ]
    low = Fact(text="Listicle claim", topic=topic, credibility="low")
    batch = FactBatch(facts=[*trustworthy, low], sources_used=["web_search"])
    sourcer = _FakeFactSourcer(batch)
    stage = SourcingStage(sourcer)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=3)

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert result.info["low_credibility_dropped"] == 1
    assert len(ctx.facts) == 3


# --- #153 topic-count scaling with order size ------------------------------


@pytest.mark.asyncio
async def test_topic_count_scales_with_target_count() -> None:
    """A 30-question order must sample >= 15 topics from the pool — the fixed
    5-topic default would leave a handful of topics carrying the whole pack."""
    sourcer = _FakeFactSourcer(FactBatch(facts=_make_facts(5), sources_used=["wikipedia"]))
    pool = _StubPool([f"topic {i}" for i in range(15)])
    stage = SourcingStage(sourcer, topic_pool=pool)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=30, category=None, theme=None, prompt="surprise me")

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert pool.last_count == 15


@pytest.mark.asyncio
async def test_topic_count_floor_stays_default_for_small_orders() -> None:
    """DEFAULT_TOPIC_COUNT (5) stays the floor — a 4-question order must not
    sample fewer than 5 topics."""
    sourcer = _FakeFactSourcer(FactBatch(facts=_make_facts(5), sources_used=["wikipedia"]))
    pool = _StubPool([f"topic {i}" for i in range(10)])
    stage = SourcingStage(sourcer, topic_pool=pool)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=4, category=None, theme=None, prompt="surprise me")

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert pool.last_count == 5
