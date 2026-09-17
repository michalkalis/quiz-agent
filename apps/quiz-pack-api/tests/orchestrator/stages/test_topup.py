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

Spent-fact exclusion (#167, founder directive 2026-09-02) — intent: **generation
must never pay for a question that dedup is guaranteed to kill.**

- `test_spent_facts_are_excluded_from_topup_pool`: the directive itself.
- `test_exhausted_fact_pool_skips_the_round`: nothing left to write on → the
  round is skipped with a loud warning and the pack delivers short, rather
  than buying a batch dedup will drop wholesale.
- `test_initial_fact_pool_is_restored_after_topup`: the filter is scoped to
  the top-up generation call; `ctx.facts` is the untouched pool everywhere
  else, so the initial round's behaviour is unchanged.
- `test_direct_generation_passes_empty_facts_through`: direct-mode orders
  carry no facts, so the filter is inert by construction.
"""

from __future__ import annotations

import logging
import uuid
from types import SimpleNamespace
from typing import Any

import pytest

from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.stages.topup import TopUpStage
from app.sourcing.models import Fact
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
        # #167: the fact pool as the generator actually received it, per round.
        self.facts_seen: list[list[Any]] = []

    async def run(self, ctx: OrderContext, sink: Any) -> StageResult:
        self.calls.append(ctx.target_count)
        self.facts_seen.append(list(ctx.facts))
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


# ---------------------------------------------------------------------------
# Spent-fact exclusion (#167)
# ---------------------------------------------------------------------------

_SPENT_URL = "https://en.wikipedia.org/wiki/2026_in_film"

_SPENT_FACT = Fact(
    text=(
        "Paul Thomas Anderson's One Battle After Another was released in "
        "September 2026 and stars Leonardo DiCaprio."
    ),
    source_url=_SPENT_URL,
    topic="Film",
)
_FRESH_FACT = Fact(
    text="Wicked: For Good opened in November 2026, directed by Jon M. Chu.",
    source_url=_SPENT_URL,
    topic="Film",
)


def _question_on_spent_fact() -> Question:
    return Question(
        id=f"q_{uuid.uuid4().hex}",
        question="Which actor stars in One Battle After Another?",
        correct_answer="Leonardo DiCaprio",
        topic="Film",
        category="entertainment",
        difficulty="medium",
        source_url=_SPENT_URL,
    )


@pytest.mark.asyncio
async def test_spent_facts_are_excluded_from_topup_pool() -> None:
    """The founder directive: a fact already backing a surviving question is
    not handed to the generator again. In the #167 pilot it was, and every
    question written on it died in dedup as `fact key reuse` — after its
    generation and fact-check had already been billed."""
    gen = _FakeGenStage()
    stage = TopUpStage(
        gen,
        _FakeDropStage("verifying", drop_n=0),
        _FakeDropStage("scoring", drop_n=0),
        _PassthroughDedupStage(),
    )
    ctx = _make_ctx(target_count=10, initial=8)
    ctx.questions[0] = _question_on_spent_fact()
    ctx.facts = [_SPENT_FACT, _FRESH_FACT]

    await stage.run(ctx, _RecordingSink())

    assert gen.facts_seen == [[_FRESH_FACT]]


@pytest.mark.asyncio
async def test_exhausted_fact_pool_skips_the_round(
    caplog: pytest.LogCaptureFixture,
) -> None:
    """Every remaining fact is spent → the round is skipped with a loud
    warning and the pack delivers short (above the floor), rather than paying
    for a batch dedup is guaranteed to drop in full."""
    gen = _FakeGenStage()
    stage = TopUpStage(
        gen,
        _FakeDropStage("verifying", drop_n=0),
        _FakeDropStage("scoring", drop_n=0),
        _PassthroughDedupStage(),
    )
    ctx = _make_ctx(target_count=10, initial=9)  # 9/10 is above the 80% floor
    ctx.questions[0] = _question_on_spent_fact()
    ctx.facts = [_SPENT_FACT]

    with caplog.at_level(logging.WARNING):
        result = await stage.run(ctx, _RecordingSink())

    assert gen.calls == []  # no generation paid for
    assert result.info["topup_rounds"] == 0
    assert result.info["fact_pool_exhausted"] is True
    assert len(ctx.questions) == 9  # short, but not a crash
    assert "fact pool exhausted" in caplog.text


@pytest.mark.asyncio
async def test_initial_fact_pool_is_restored_after_topup() -> None:
    """The filter is scoped to the top-up generation call only — `ctx.facts`
    is the full sourced pool before and after, so the initial round (which
    runs before this stage) is untouched by construction."""
    gen = _FakeGenStage()
    stage = TopUpStage(
        gen,
        _FakeDropStage("verifying", drop_n=0),
        _FakeDropStage("scoring", drop_n=0),
        _PassthroughDedupStage(),
    )
    ctx = _make_ctx(target_count=10, initial=8)
    ctx.questions[0] = _question_on_spent_fact()
    pool = [_SPENT_FACT, _FRESH_FACT]
    ctx.facts = pool

    await stage.run(ctx, _RecordingSink())

    assert ctx.facts == pool


@pytest.mark.asyncio
async def test_direct_generation_passes_empty_facts_through() -> None:
    """Direct-generation orders source no facts (#153 Phase 0.4), so the
    exclusion is inert: the generator still sees an empty pool and the round
    runs normally. Pins that #167 cannot starve the direct path."""
    gen = _FakeGenStage()
    stage = TopUpStage(
        gen,
        _FakeDropStage("verifying", drop_n=0),
        _FakeDropStage("scoring", drop_n=0),
        _PassthroughDedupStage(),
    )
    ctx = _make_ctx(target_count=10, initial=7)
    ctx.direct_generation = True
    ctx.facts = []

    result = await stage.run(ctx, _RecordingSink())

    assert gen.calls == [3]
    assert gen.facts_seen == [[]]
    assert ctx.facts == []
    assert result.info["final_count"] == 10
    assert result.info["fact_pool_exhausted"] is False


# ── #182 incremental delivery ────────────────────────────────────────────────
# Intent: a player can start on the first small batch while the rest keeps
# generating. The contract is (1) the first round is small, later rounds are
# chunk-sized, (2) every round's accepted tail is persisted immediately and
# locked, (3) a retried attempt resumes on what was already delivered instead
# of regenerating or duplicating it, (4) the run ends by closing the pack.


class _FakePersistStage:
    name = "persisting"

    def __init__(self, existing: list[Question] | None = None) -> None:
        self.existing = existing or []
        self.batches: list[list[Question]] = []
        self.locked_seen: list[int] = []
        self.finalized: str | None = None
        self.pack = SimpleNamespace(id=uuid.uuid4())

    async def load_existing(self, ctx: OrderContext):
        if not self.existing:
            return None
        ctx.questions = list(self.existing)
        ctx.locked_count = len(self.existing)
        return self.pack

    async def persist_batch(self, ctx: OrderContext, new_questions: list[Question]):
        self.batches.append(list(new_questions))
        self.locked_seen.append(ctx.locked_count)
        return self.pack

    async def finalize(self, ctx: OrderContext, status: str):
        self.finalized = status
        return self.pack


class _CountingSink(_RecordingSink):
    def __init__(self) -> None:
        self.steps: list[tuple[str, Any]] = []
        self.published: list[tuple[str, int]] = []

    async def start_step(self, step: str, info: Any = None) -> int:
        self.steps.append((step, info))
        return len(self.steps)

    async def publish(self, event_id: int, step: str, progress: int, info: Any = None) -> None:
        self.published.append((step, progress))


def _incremental_stage(persist: _FakePersistStage, gen: _FakeGenStage, **kw) -> TopUpStage:
    return TopUpStage(
        gen,
        _FakeDropStage("verifying", 0),
        _FakeDropStage("scoring", 0),
        _PassthroughDedupStage(),
        persist_stage=persist,
        first_chunk=5,
        chunk_size=10,
        **kw,
    )


@pytest.mark.asyncio
async def test_incremental_persists_every_round_and_closes_the_pack() -> None:
    gen = _FakeGenStage()
    persist = _FakePersistStage()
    sink = _CountingSink()
    ctx = _make_ctx(target_count=30, initial=0)

    result = await _incremental_stage(persist, gen).run(ctx, sink)

    # First round is the small one the player starts on; the rest are chunks.
    assert gen.calls == [5, 10, 10, 5]
    # Each round's new tail was written right away …
    assert [len(b) for b in persist.batches] == [5, 10, 10, 5]
    # … on top of what was already locked (nothing rewritten).
    assert persist.locked_seen == [0, 5, 15, 25]
    assert ctx.locked_count == 30
    assert persist.finalized == "complete"
    assert result.info["pack"] is persist.pack
    # A `round` step per persisted batch carries the playable count.
    rounds = [info for step, info in sink.steps if step == "round"]
    assert [r["ready"] for r in rounds] == [5, 15, 25, 30]
    assert sink.published[-1] == ("round", 99)


@pytest.mark.asyncio
async def test_incremental_resume_continues_from_persisted_questions() -> None:
    """An ARQ retry / manual retry must NOT regenerate what a player may
    already be playing: existing pack questions are loaded as the locked
    prefix and only the shortfall is generated."""
    existing = [_stub_question(f"delivered {i}") for i in range(12)]
    gen = _FakeGenStage()
    persist = _FakePersistStage(existing=existing)
    ctx = _make_ctx(target_count=30, initial=0)

    await _incremental_stage(persist, gen).run(ctx, _CountingSink())

    assert gen.calls == [10, 8]
    assert persist.locked_seen == [12, 22]
    assert ctx.questions[:12] == existing
    assert persist.finalized == "complete"


@pytest.mark.asyncio
async def test_incremental_round_budget_scales_with_chunking() -> None:
    """`max_rounds` keeps meaning "extra rounds": a 30-pack in 5+10+10+5
    needs 4 rounds on its own, so a lossy pipeline still gets its two
    retries on top instead of failing the floor after 2 rounds."""
    gen = _FakeGenStage()
    persist = _FakePersistStage()
    ctx = _make_ctx(target_count=30, initial=0)
    stage = TopUpStage(
        gen,
        _FakeDropStage("verifying", 2),
        _FakeDropStage("scoring", 0),
        _PassthroughDedupStage(),
        persist_stage=persist,
        first_chunk=5,
        chunk_size=10,
        max_rounds=2,
    )

    await stage.run(ctx, _CountingSink())

    assert len(gen.calls) <= 6
    assert len(ctx.questions) >= 24  # above the 80 % floor
    assert persist.finalized == "complete"


@pytest.mark.asyncio
async def test_incremental_floor_failure_keeps_pack_open_for_retry() -> None:
    """Below the floor the stage still raises (fail loud), but it must not
    close the pack: the retry resumes on it, and the worker's failure path
    decides between `generating` (retry pending) and `failed` (final)."""
    gen = _FakeGenStage()
    persist = _FakePersistStage()
    ctx = _make_ctx(target_count=30, initial=0)
    stage = TopUpStage(
        gen,
        _FakeDropStage("verifying", 4),
        _FakeDropStage("scoring", 0),
        _PassthroughDedupStage(),
        persist_stage=persist,
        first_chunk=5,
        chunk_size=10,
        max_rounds=0,
    )

    with pytest.raises(ValueError, match="pack shortfall"):
        await stage.run(ctx, _CountingSink())

    assert persist.finalized is None
    assert persist.batches, "rounds that did survive were persisted before the floor check"


def test_incremental_requires_chunk_sizes() -> None:
    with pytest.raises(ValueError, match="first_chunk"):
        TopUpStage(
            _FakeGenStage(),
            _FakeDropStage("verifying", 0),
            _FakeDropStage("scoring", 0),
            _PassthroughDedupStage(),
            persist_stage=_FakePersistStage(),
        )
