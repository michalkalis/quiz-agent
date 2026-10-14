"""#203 203.9 — customer packs split into narrow sub-themes (``PACK_SUBTHEMES``)
plus the in-pack cosine check, run through the REAL #182 round walk.

Why the real walk: TopUpStage retargets ``ctx.target_count`` to each round's
shortfall (1, 2, 4, 8, 8, 7 for a 30-pack), so a planner tested against one
generation call proves nothing about quotas, totals or retries. Every walk
below drives ``TopUpStage(batch_schedule=(1, 2, 4, 8))`` with the real
GenerationStage, DedupStage and CompositionStage; only the LLM edges
(generator, planner, embeddings) and the database (persist) are fakes.

What each test protects:

- the founder's shape (3-4 questions per narrow sub-theme) without slowing
  the first question (#182) or missing the exact pack size;
- a question lost to verification is owed again, and a retried attempt
  continues the plan it already started instead of re-splitting a half-built
  pack (which would overshoot every quota);
- the planner can never fail a paid order;
- flag off, and every non-customer path (corpus CLI, #202), stays as before;
- two sub-themes generated concurrently cannot see each other, so a
  paraphrase is caught by the in-pack cosine, which word overlap misses.
"""

from __future__ import annotations

import asyncio
import random
import uuid
from collections import Counter
from typing import Any

import pytest
from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.stages import subthemes
from app.orchestrator.stages.composition import CompositionStage
from app.orchestrator.stages.dedup import DedupStage
from app.orchestrator.stages.generation import GenerationStage
from app.orchestrator.stages.topup import TopUpStage
from quiz_shared.models.question import Question

from tests.orchestrator.stages.test_topup import (
    _CountingSink,
    _FakeDropStage,
    _FakePersistStage,
)

SUBTHEMES = [f"sub-theme {c}" for c in "ABCDEFGHI"]  # ceil(30 / 3.5) = 9
WHOLE_TOPIC = ["Harry Potter"]


def _question(
    n: int, text: str | None = None, answer: str | None = None, topic: str | None = None
) -> Question:
    # Token-disjoint texts/answers, so word-overlap dedup never fires by
    # accident and only what a test scripts can collide.
    return Question(
        id=f"q_{n}",
        question=text or f"fact{n} alpha{n}x beta{n}y?",
        correct_answer=answer or f"answer{n}",
        topic=topic or f"label {n}",
        category="general",
        difficulty="medium",
    )


class _Generator:
    """Deterministic stand-in for AdvancedQuestionGenerator: fresh questions
    per call; `scripted[call_no]` replaces the first texts of that call."""

    def __init__(self, scripted: dict[int, list[tuple[str, str]]] | None = None) -> None:
        self.calls: list[dict[str, Any]] = []
        self._n = 0
        self._scripted = scripted or {}
        self.on_call = None

    async def generate_questions(self, **kwargs: Any) -> list[Question]:
        self.calls.append(kwargs)
        if self.on_call is not None:
            self.on_call()
        script = self._scripted.get(len(self.calls), [])
        # A model labels every question of one narrow sub-theme the same way:
        # CompositionStage's per-topic cap (2 per 30-pack) must not trim a
        # 3-4 question sub-theme. Whole-topic calls get varied labels.
        themed = kwargs["topics"] != WHOLE_TOPIC
        out = []
        for i in range(kwargs["count"]):
            self._n += 1
            text, answer = script[i] if i < len(script) else (None, None)
            out.append(
                _question(self._n, text, answer, "Harry Potter" if themed else None)
            )
        return out


class _Planner:
    def __init__(self, names: list[str] | None = SUBTHEMES, raises: bool = False) -> None:
        self.names = names
        self.raises = raises
        self.calls: list[tuple[str, str, int]] = []
        self.release: asyncio.Event | None = None

    async def propose_subthemes(self, request: str, language: str, count: int):
        self.calls.append((request, language, count))
        if self.release is not None:
            await self.release.wait()
        if self.raises:
            raise RuntimeError("planner down")
        return None if self.names is None else self.names[:count]


class _Store:
    """Embeddings + an empty corpus. Unscripted texts get random 256-dim
    vectors (pairwise cosine ~0.06 ± 0.06, far below 0.85)."""

    def __init__(self, vectors: dict[str, list[float]] | None = None) -> None:
        self.vectors = vectors or {}
        self.embedded: list[str] = []
        self.query_embeddings: list[Any] = []

    async def embed(self, text: str) -> list[float]:
        self.embedded.append(text)
        if text in self.vectors:
            return self.vectors[text]
        rng = random.Random(text)
        return [rng.gauss(0, 1) for _ in range(256)]

    async def find_duplicates(self, question_text: str, threshold: float = 0.85, **kw):
        self.query_embeddings.append(kw.get("query_embedding"))
        return []


def _ctx(target: int = 30) -> OrderContext:
    return OrderContext(
        order_id=uuid.uuid4(),
        prompt="Harry Potter",
        language="en",
        target_count=target,
        theme="Harry Potter",
        direct_generation=True,
    )


def _walk(
    gen: _Generator,
    planner: _Planner,
    *,
    store: _Store | None = None,
    persist: _FakePersistStage | None = None,
    verify=None,
    customer_order: bool = True,
    in_pack_cosine: bool = True,
) -> TopUpStage:
    return TopUpStage(
        GenerationStage(gen, customer_order=customer_order, subtheme_planner=planner),
        verify or _FakeDropStage("verifying", 0),
        _FakeDropStage("scoring", 0),
        DedupStage(store or _Store(), None, in_pack_cosine=in_pack_cosine),
        composition_stage=CompositionStage(),
        persist_stage=persist or _FakePersistStage(),
        batch_schedule=(1, 2, 4, 8),
    )


async def _run(stage: TopUpStage, ctx: OrderContext) -> StageResult:
    # A walk that waits on something it should not would hang, not fail.
    return await asyncio.wait_for(stage.run(ctx, _CountingSink()), timeout=5)


def _counts(ctx: OrderContext) -> Counter:
    return Counter(subthemes.stamp_of(q) for q in ctx.questions)


def _quotas(ctx: OrderContext) -> dict[str, int]:
    return {p["name"]: p["quota"] for p in ctx.subtheme_plan or []}


@pytest.fixture
def subthemes_on(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PACK_SUBTHEMES", "1")


@pytest.mark.usefixtures("subthemes_on")
async def test_round_one_whole_topic_then_subtheme_quotas_fill_the_pack() -> None:
    """The founder's shape: 30 questions = round 1 on the whole topic (first
    question fast, #182) + 9 narrow sub-themes of 3-4, exact pack size."""
    gen, planner = _Generator(), _Planner()
    planner.release = asyncio.Event()
    # The planner only answers once round 1 is generating: if round 1 waited
    # for the plan, this walk would deadlock (and time out).
    gen.on_call = planner.release.set
    persist = _FakePersistStage()
    ctx = _ctx(30)

    await _run(_walk(gen, planner, persist=persist), ctx)

    assert planner.calls == [("Harry Potter", "en", 9)]  # once per order
    assert gen.calls[0]["count"] == 1 and gen.calls[0]["topics"] == WHOLE_TOPIC
    later = gen.calls[1:]
    assert all(len(c["topics"]) == 1 and c["topics"][0] in SUBTHEMES for c in later)
    # One call never asks a sub-theme for more than its quota.
    assert all(c["count"] <= subthemes.MAX_QUOTA for c in later)
    # The #182 ramp is untouched: same batches persisted as without sub-themes.
    assert [len(b) for b in persist.batches] == [1, 2, 4, 8, 8, 7]
    assert len(ctx.questions) == 30
    counts = _counts(ctx)
    assert counts.pop(None) == 1  # round 1's question
    assert dict(counts) == _quotas(ctx)
    assert set(counts.values()) <= {3, 4} and sum(counts.values()) == 29


@pytest.mark.usefixtures("subthemes_on")
async def test_subtheme_calls_keep_the_house_style(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Changes 1 and 2 of 203.9 ship together: every per-sub-theme call must
    carry the house-style brief and every sub-theme question both stamps,
    exactly like the whole-topic call, or the blind round would test
    sub-themes without the style that made the corpus fun."""
    from app.generation.prompt_builder import HOUSE_STYLE_VERSION

    monkeypatch.setenv("GEN_HOUSE_STYLE", "1")
    gen = _Generator()
    ctx = _ctx(30)

    await _run(_walk(gen, _Planner()), ctx)

    assert len(gen.calls) > 1
    assert all("## HOUSE STYLE" in c["order_brief"] for c in gen.calls)
    themed = [q for q in ctx.questions if subthemes.stamp_of(q) is not None]
    assert len(themed) == 29
    assert all(
        q.generation_metadata.extra["house_style"] == HOUSE_STYLE_VERSION
        and q.generation_metadata.extra["subtheme"] in SUBTHEMES
        for q in themed
    )


@pytest.mark.usefixtures("subthemes_on")
async def test_dropped_questions_are_owed_again() -> None:
    """Quotas are counted from the stamps of what survived, so a question
    verification drops is regenerated on the SAME sub-theme, and the pack
    still ends at exactly its target."""

    class _DropFirstOfCalls:
        name = "verifying"

        def __init__(self, calls: set[int]) -> None:
            self._calls, self._seen = calls, 0

        async def run(self, ctx: OrderContext, sink: Any) -> StageResult:
            self._seen += 1
            if self._seen in self._calls and ctx.questions:
                ctx.questions = ctx.questions[1:]
            return StageResult()

    gen, planner = _Generator(), _Planner()
    ctx = _ctx(30)

    await _run(_walk(gen, planner, verify=_DropFirstOfCalls({3, 5})), ctx)

    assert len(ctx.questions) == 30
    counts = _counts(ctx)
    assert counts.pop(None) == 1
    assert dict(counts) == _quotas(ctx)


@pytest.mark.usefixtures("subthemes_on")
async def test_retry_resumes_the_stamped_plan_without_replanning() -> None:
    """An ARQ retry must continue the plan the first attempt started: the plan
    rides on the persisted stamps, so the planner is not called again and no
    sub-theme gets more than its quota."""
    plan = subthemes.split_quotas(SUBTHEMES, 29)
    delivered = [_question(1000)]  # round 1, unstamped
    a = [_question(1001 + i) for i in range(plan[0]["quota"])]
    b = [_question(1100 + i) for i in range(2)]
    subthemes.stamp(a, plan[0]["name"], plan)
    subthemes.stamp(b, plan[1]["name"], plan)
    delivered += a + b
    gen, planner = _Generator(), _Planner()
    persist = _FakePersistStage(existing=delivered)
    ctx = _ctx(30)

    await _run(_walk(gen, planner, persist=persist), ctx)

    assert planner.calls == []
    assert ctx.questions[: len(delivered)] == delivered
    assert all(c["topics"] != [plan[0]["name"]] for c in gen.calls)  # A was full
    assert len(ctx.questions) == 30
    counts = _counts(ctx)
    assert counts.pop(None) == 1
    assert dict(counts) == {p["name"]: p["quota"] for p in plan}


@pytest.mark.usefixtures("subthemes_on")
async def test_retry_without_stamps_plans_from_what_was_delivered() -> None:
    """No stamped question yet → re-planning is safe; the quotas only split
    what the delivered, unthemed questions leave of the target."""
    delivered = [_question(2000 + i) for i in range(3)]
    gen, planner = _Generator(), _Planner()
    ctx = _ctx(30)

    await _run(_walk(gen, planner, persist=_FakePersistStage(existing=delivered)), ctx)

    assert len(planner.calls) == 1
    assert len(ctx.questions) == 30
    counts = _counts(ctx)
    unthemed = counts.pop(None)
    assert unthemed + sum(_quotas(ctx).values()) == 30
    assert dict(counts) == _quotas(ctx)


@pytest.mark.usefixtures("subthemes_on")
@pytest.mark.parametrize("planner", [_Planner(names=None), _Planner(raises=True)])
async def test_planner_failure_keeps_the_whole_topic(planner: _Planner) -> None:
    """A planner that answers nothing or raises must leave the pack exactly as
    before (whole topic every round) and never fail the order."""
    gen = _Generator()
    ctx = _ctx(30)

    await _run(_walk(gen, planner), ctx)

    assert len(planner.calls) == 1
    assert ctx.subtheme_plan == []
    assert all(c["topics"] == WHOLE_TOPIC for c in gen.calls)
    assert len(ctx.questions) == 30 and _counts(ctx) == Counter({None: 30})


async def test_flag_off_is_unchanged(monkeypatch: pytest.MonkeyPatch) -> None:
    """PACK_SUBTHEMES off: a customer order's generation calls are identical
    to a stage built without the customer flag (the pre-#203 construction),
    nothing is planned, embedded or stamped."""
    monkeypatch.delenv("PACK_SUBTHEMES", raising=False)
    runs = []
    for customer_order in (True, False):
        gen, planner, store = _Generator(), _Planner(), _Store()
        ctx = _ctx(30)
        await _run(
            _walk(
                gen,
                planner,
                store=store,
                customer_order=customer_order,
                in_pack_cosine=False,
            ),
            ctx,
        )
        assert planner.calls == [] and store.embedded == []
        assert set(store.query_embeddings) == {None}
        assert ctx.pack_embeddings == {} and _counts(ctx) == Counter({None: 30})
        runs.append(gen.calls)
    assert runs[0] == runs[1]


@pytest.mark.usefixtures("subthemes_on")
async def test_only_the_customer_worker_opts_in(monkeypatch: pytest.MonkeyPatch) -> None:
    """The flag is a prod secret in the Fly app the #202 job also runs in, and
    corpus runs share GenerationStage: only the worker's explicit customer
    flag may turn sub-themes (and the in-pack check) on."""
    from app.orchestrator.offline_stages import build_stages
    from app.worker.tasks import _build_stages as build_worker_stages

    # A non-customer stage never plans, even with the flag on.
    gen, planner = _Generator(), _Planner()
    ctx = _ctx(30)
    await _run(_walk(gen, planner, customer_order=False, in_pack_cosine=False), ctx)
    assert planner.calls == [] and _counts(ctx) == Counter({None: 30})

    monkeypatch.setenv("TAVILY_API_KEY", "tvly-test-placeholder")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test-placeholder")
    offline = next(
        s
        for s in build_stages(persist=False, dedup_store=_Store())
        if isinstance(s, TopUpStage)
    )
    assert offline._generation_stage._customer_order is False
    assert offline._dedup_stage._in_pack_cosine is False

    worker = next(
        s
        for s in build_worker_stages(
            {
                "generator": object(),
                "fact_verifier": object(),
                "scorer": object(),
                "question_store": _Store(),
                "fact_sourcer": object(),
                "session_factory": object(),
            }
        )
        if isinstance(s, TopUpStage)
    )
    assert worker._generation_stage._customer_order is True
    assert worker._dedup_stage._in_pack_cosine is True


@pytest.mark.usefixtures("subthemes_on")
@pytest.mark.parametrize("in_pack_cosine", [True, False])
async def test_in_pack_cosine_drops_a_paraphrase_from_an_earlier_round(
    in_pack_cosine: bool,
) -> None:
    """Round 3 paraphrases round 1's question with almost no shared words:
    word-overlap dedup lets it through (the `False` arm proves it), only the
    in-pack cosine against the pack's earlier rounds catches it."""
    original = ("Which house does Harry Potter belong to?", "Gryffindor")
    paraphrase = ("Harry ends up sorted into what Hogwarts house?", "Gryffindor")
    base = [random.Random(1).gauss(0, 1) for _ in range(256)]
    store = _Store(
        {original[0]: base, paraphrase[0]: [x + 0.05 for x in base]}
    )
    # Call 1 = round 1; calls 2.. are sub-theme calls of later rounds.
    gen = _Generator(scripted={1: [original], 3: [paraphrase]})
    ctx = _ctx(30)

    await _run(_walk(gen, _Planner(), store=store, in_pack_cosine=in_pack_cosine), ctx)

    texts = [q.question for q in ctx.questions]
    assert original[0] in texts
    assert (paraphrase[0] in texts) is not in_pack_cosine
    assert len(ctx.questions) == 30  # the dropped one is regenerated
    if in_pack_cosine:
        # Kept in memory across rounds: no text is embedded twice, and the
        # corpus lookup reuses the same vector instead of embedding again.
        assert len(store.embedded) == len(set(store.embedded))
        assert None not in store.query_embeddings


async def test_in_pack_cosine_catches_batchmates_but_never_a_delivered_question() -> None:
    """Concurrent sub-theme calls land in one batch; the later paraphrase is
    dropped. A question already persisted (#182 locked prefix) may be
    mid-play and is never dropped, even when it collides."""
    base = [random.Random(2).gauss(0, 1) for _ in range(256)]
    a = _question(1, "Which house does Harry Potter belong to?", "Gryffindor")
    b = _question(2, "Harry ends up sorted into what Hogwarts house?", "Gryffindor")
    store = _Store({a.question: base, b.question: [x + 0.05 for x in base]})
    dedup = DedupStage(store, None, in_pack_cosine=True)

    ctx = _ctx(2)
    ctx.questions = [a, b]
    result = await dedup.run(ctx, _CountingSink())
    assert [q.id for q in ctx.questions] == ["q_1"]
    assert result.info["drop_reasons"]["in_pack_cosine"] == 1

    ctx = _ctx(2)
    ctx.questions, ctx.locked_count = [a, b], 2
    await dedup.run(ctx, _CountingSink())
    assert [q.id for q in ctx.questions] == ["q_1", "q_2"]


@pytest.mark.parametrize("target", range(7, 31))
def test_quota_split_is_three_to_four_and_sums_to_the_budget(target: int) -> None:
    """For every pack size from 7 up, the planner's `ceil(target/3.5)`
    sub-themes split `target - 1` (round 1's question) into 3-4 each with
    nothing left over. (At 6 the budget 5 cannot be split into 3-4s; the
    rest is generated on the whole topic, see `allocate`.)"""
    names = SUBTHEMES * 4
    plan = subthemes.split_quotas(names[: subthemes.subtheme_count(target)], target - 1)
    quotas = [p["quota"] for p in plan]
    assert sum(quotas) == target - 1
    assert set(quotas) <= {3, 4}


def test_allocate_takes_the_largest_remaining_quota_first() -> None:
    plan = [{"name": "A", "quota": 3}, {"name": "B", "quota": 4}, {"name": "C", "quota": 4}]
    done = [_question(1)]
    subthemes.stamp(done, "B", plan)
    # B owes 3, C owes 4 → C first; anything beyond the plan is whole-topic.
    assert subthemes.allocate(plan, done, 5) == [("C", 4), ("A", 1)]
    assert subthemes.allocate(plan, done, 12) == [("C", 4), ("A", 3), ("B", 3), (None, 2)]
