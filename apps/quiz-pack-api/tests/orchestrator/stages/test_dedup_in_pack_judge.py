"""Same fact twice in one customer pack (`DedupStage(in_pack_judge=...)`).

Why: a real 10-question Slovak kids pack on LEGO (2026-11-18) asked "they
built a life-size LEGO car; what could a grown-up do with it?" (drive it) and
then "true or false: the life-size LEGO car could really be driven" (true).
The player hears the answer to one inside the other. Sub-theme calls run
concurrently and cannot see each other, a customer pack has no per-topic
cap, and every word/cosine check let the pair through: the true/false form
shares few words with the open one (Slovak inflection: LEGO/LEGA,
skutočné/skutočnej) and sits below the 0.85 in-pack cosine. Only a "same
fact?" verdict separates it, so customer packs ask the gray-zone judge about
each new question and its nearest questions already in the pack.

What each test protects: the pair above is caught in one round across two
sub-themes and the pack still fills; a delivered or already-cleared question
is never judged again (a played question cannot be taken back, and the top-up
walk relies on dedup never dropping an accepted question); a judge outage
keeps the question; only customer orders get the judge.
"""

from __future__ import annotations

import random
import uuid
from typing import Any

import pytest
from app.orchestrator.context import OrderContext
from app.orchestrator.stages import subthemes
from app.orchestrator.stages.composition import CompositionStage
from app.orchestrator.stages.dedup import (
    DEFAULT_COSINE_THRESHOLD,
    DedupStage,
    _fact_tokens,
    _jaccard,
)
from app.orchestrator.stages.grayzone_judge import GrayZoneJudge
from langchain_core.messages import AIMessage
from quiz_shared.models.question import Question

from tests.orchestrator.stages.test_pack_subthemes import (
    _CountingSink,
    _Generator,
    _Planner,
    _run,
    _Store,
    _walk,
)

OPEN = (
    (
        "Z LEGO dielikov postavili auto veľké ako skutočné. Čo s ním potom "
        "dokázal urobiť dospelý človek?"
    ),
    "Jazdiť v ňom",
)
TRUE_FALSE = (
    (
        "Pravda alebo nepravda: z LEGA postavili auto v skutočnej veľkosti a "
        "dalo sa ním naozaj jazdiť."
    ),
    "Pravda",
)
ANGLES = [
    "record builds",
    "how a brick is made",
    "how much a brick holds",
    "company history",
    "the founder's wooden toys",
    "minifigures",
    "LEGO parks",
]


class _SameFactClient:
    """`chat_openai`-shaped judge double: YES only for the LEGO-car pair,
    whatever order the concurrent calls arrive in."""

    def __init__(self, fail: bool = False, always_no: bool = False) -> None:
        self.prompts: list[str] = []
        self.fail = fail
        self.always_no = always_no

    async def ainvoke(self, prompt: str) -> AIMessage:
        self.prompts.append(prompt)
        if self.fail:
            raise RuntimeError("judge down")
        pair = OPEN[0] in prompt and TRUE_FALSE[0] in prompt
        return AIMessage(content="YES" if pair and not self.always_no else "NO")


def _judge(client: _SameFactClient) -> GrayZoneJudge:
    return GrayZoneJudge(model="test-judge", max_calls=150, client=client)


def _vectors() -> dict[str, list[float]]:
    """The pair sits at cosine ~0.75: same topic, below the 0.85 in-pack drop."""
    rng = random.Random(7)
    base = [rng.gauss(0, 1) for _ in range(256)]
    return {OPEN[0]: base, TRUE_FALSE[0]: [x + rng.gauss(0, 0.88) for x in base]}


def _cos(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    return dot / (sum(x * x for x in a) ** 0.5 * sum(y * y for y in b) ** 0.5)


def _q(n: int, text: str, answer: str) -> Question:
    return Question(
        id=f"q_{n}",
        question=text,
        correct_answer=answer,
        topic="LEGO",
        category="general",
        difficulty="easy",
    )


def _lego_ctx(target: int = 10) -> OrderContext:
    return OrderContext(
        order_id=uuid.uuid4(),
        prompt="LEGO: ako sa vyrába kocka, rekordné stavby, história firmy",
        language="sk",
        target_count=target,
        theme="LEGO",
        direct_generation=True,
        audience="kids_7_9",
    )


@pytest.fixture
def kids_pack(monkeypatch: pytest.MonkeyPatch) -> None:
    from app import kids_check

    async def keep_all(questions, band):
        return questions, {"length": 0, "theme": 0}

    monkeypatch.setenv("PACK_SUBTHEMES", "1")
    monkeypatch.setattr(kids_check, "filter_questions", keep_all)


def test_the_pair_defeats_every_word_and_cosine_check() -> None:
    """The premise: without a verdict nothing separates the pair."""
    assert _jaccard(_fact_tokens(_q(1, *OPEN)), _fact_tokens(_q(2, *TRUE_FALSE))) < 0.35
    vectors = _vectors()
    assert 0.70 < _cos(vectors[OPEN[0]], vectors[TRUE_FALSE[0]]) < DEFAULT_COSINE_THRESHOLD


@pytest.mark.usefixtures("kids_pack")
@pytest.mark.parametrize("judged", [True, False])
async def test_same_fact_from_two_subthemes_in_one_round_keeps_one(judged: bool) -> None:
    """Round 3 of a kids_7_9 10-pack: two concurrent sub-theme calls, the open
    question from one and its true/false rewording from the other. The judge
    drops the later one, the top-up refills, and the pack is still 10."""
    # Calls 1-3 are rounds 1-2 (1 whole-topic call, then 2 sub-themes of 1);
    # calls 4 and 5 are two sub-themes of round 3.
    gen = _Generator(scripted={4: [OPEN], 5: [TRUE_FALSE]})
    client = _SameFactClient()
    store = _Store(_vectors())
    walk = _walk(gen, _Planner(names=ANGLES), store=store)
    # The worker's stages: in-pack cosine on, judge on, no per-topic cap.
    walk._dedup_stage = DedupStage(
        store, None, in_pack_cosine=True, in_pack_judge=_judge(client) if judged else None
    )
    walk._composition_stage = CompositionStage(customer_order=True)
    rounds: list[int] = []
    call_rounds: list[int] = []
    generate = walk._generation_stage.run

    async def counted(ctx, sink):
        rounds.append(len(rounds) + 1)
        return await generate(ctx, sink)

    walk._generation_stage.run = counted  # type: ignore[method-assign]
    gen.on_call = lambda: call_rounds.append(len(rounds))
    ctx = _lego_ctx()

    await _run(walk, ctx)

    # The two arrived in one round from two different sub-themes.
    assert call_rounds[3] == call_rounds[4] == 3
    assert gen.calls[3]["topics"] != gen.calls[4]["topics"]
    stamps = {subthemes.stamp_of(q) for q in ctx.questions if q.question == OPEN[0]}
    assert stamps and None not in stamps
    texts = [q.question for q in ctx.questions]
    assert OPEN[0] in texts
    assert (TRUE_FALSE[0] in texts) is not judged
    assert len(ctx.questions) == 10  # the dropped one is regenerated
    if judged:
        assert sum(OPEN[0] in p and TRUE_FALSE[0] in p for p in client.prompts) == 1
        # Every question is judged once: no prompt repeats across rounds.
        assert len(client.prompts) == len(set(client.prompts))


async def test_a_delivered_or_cleared_question_is_never_judged_again() -> None:
    """A persisted question may be mid-play, and the top-up walk relies on
    dedup never dropping a question it accepted: neither is judged twice."""
    client = _SameFactClient()
    dedup = DedupStage(_Store(_vectors()), None, in_pack_judge=_judge(client))
    a, b = _q(1, *OPEN), _q(2, *TRUE_FALSE)

    ctx = _lego_ctx(2)
    ctx.questions, ctx.locked_count = [a, b], 2
    result = await dedup.run(ctx, _CountingSink())
    assert [q.id for q in ctx.questions] == ["q_1", "q_2"]
    assert client.prompts == [] and result.info["in_pack_judge_calls"] == 0

    # A "no" is final: the next round re-runs dedup over the merged list.
    client_no = _SameFactClient(always_no=True)
    dedup = DedupStage(_Store(_vectors()), None, in_pack_judge=_judge(client_no))
    ctx = _lego_ctx(2)
    ctx.questions = [a, b]
    await dedup.run(ctx, _CountingSink())
    await dedup.run(ctx, _CountingSink())
    assert [q.id for q in ctx.questions] == ["q_1", "q_2"]
    assert len(client_no.prompts) == 1


async def test_judge_outage_keeps_the_question() -> None:
    """Like every other dedup outage: a failing judge never drops a paid question."""
    client = _SameFactClient(fail=True)
    dedup = DedupStage(_Store(_vectors()), None, in_pack_judge=_judge(client))
    ctx = _lego_ctx(2)
    ctx.questions = [_q(1, *OPEN), _q(2, *TRUE_FALSE)]
    result = await dedup.run(ctx, _CountingSink())
    assert len(ctx.questions) == 2 and len(client.prompts) == 1
    assert result.info["drop_reasons"]["in_pack_judge"] == 0


async def test_drop_is_recorded_with_its_own_reason() -> None:
    client = _SameFactClient()
    dedup = DedupStage(_Store(_vectors()), None, in_pack_judge=_judge(client))
    ctx = _lego_ctx(2)
    ctx.questions = [_q(1, *OPEN), _q(2, *TRUE_FALSE)]
    result = await dedup.run(ctx, _CountingSink())
    assert [q.id for q in ctx.questions] == ["q_1"]
    assert result.info["drop_reasons"]["in_pack_judge"] == 1
    assert result.info["fact_dropped"] == 1
    row = next(d for d in dedup.last_decisions if d["id"] == "q_2")
    assert row["reason"] == "in_pack_judge" and row["match_id"] == "q_1"


def _worker_dedup() -> Any:
    from app.orchestrator.stages.topup import TopUpStage
    from app.worker.tasks import _build_stages

    stages = _build_stages(
        {
            "generator": object(),
            "fact_verifier": object(),
            "scorer": object(),
            "question_store": _Store(),
            "fact_sourcer": object(),
            "session_factory": object(),
        }
    )
    return next(s for s in stages if isinstance(s, TopUpStage))._dedup_stage


def test_customer_orders_get_the_judge_with_subthemes_on_or_off(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Every customer pack, any audience, sub-themes or not; the flag is the
    rollback lever. The corpus CLI walk is unchanged."""
    from app.orchestrator.offline_stages import build_stages
    from app.orchestrator.stages.topup import TopUpStage

    monkeypatch.setenv("PACK_SAME_FACT_JUDGE", "1")
    for subthemes_flag in ("1", "0"):
        monkeypatch.setenv("PACK_SUBTHEMES", subthemes_flag)
        assert isinstance(_worker_dedup()._in_pack_judge, GrayZoneJudge)

    monkeypatch.setenv("TAVILY_API_KEY", "tvly-test-placeholder")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test-placeholder")

    def offline(customer_order: bool) -> DedupStage:
        stages = build_stages(
            persist=False, dedup_store=_Store(), customer_order=customer_order
        )
        return next(s for s in stages if isinstance(s, TopUpStage))._dedup_stage

    assert isinstance(offline(True)._in_pack_judge, GrayZoneJudge)
    assert offline(False)._in_pack_judge is None

    monkeypatch.setenv("PACK_SAME_FACT_JUDGE", "0")
    assert _worker_dedup()._in_pack_judge is None
