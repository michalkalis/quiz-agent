"""#236 — the quality checks after generation judge a child-band pack for
that child (founder 2026-11-15: "fun for an adult is not fun for a child, nor
for a child of a different age").

Why these matter: the judges, the casual-player check and the T/F cap were
written for adult packs. Unchanged, they score a 7-year-old's question as if
a pub-quiz adult played it, drop a good short "why" answer as too long, and
cut a 4-6 pack (two options by design) down to one T/F question. Every adult
order must stay byte-for-byte as before: same prompts, same calls.
"""

from __future__ import annotations

import asyncio
import hashlib
import uuid
from datetime import date
from types import SimpleNamespace
from typing import Any

import pytest
from app import audience, kids_check
from app.orchestrator import OrderContext
from app.orchestrator.stages.composition import CompositionStage
from app.orchestrator.stages.scoring import ScoringStage
from app.scoring import craft_guards
from app.scoring.multi_model_scorer import SCORING_DIMENSIONS, MultiModelScorer
from app.verification.casual_player import CasualPlayerChecker
from quiz_shared.models.question import Question

BANDS = ("kids_4_6", "kids_7_9", "kids_10_12")

# sha256 of the adult judge prompts rendered by the code BEFORE #236's band
# work (origin/main 3e15aea4). A mismatch means an adult prompt changed: only
# update these on a deliberate, founder-approved change to adult scoring.
ADULT_PROMPT_SHA = {
    "v1": "5e475ed8e6c0e8ceea83e1a50b0971edeb5dbcd5d95c11c38bee3835a69dc99b",
    "v2": "92aa2a3dd5608e7d5a6d3fdc6d41cc937a3282d03c3e0c3bf0c80deae7c54819",
    "v2_clustered": "c27018b39f79b32fb0bdd8ea9bc6fdc5f4057b837ff968a3e9c353823d377a63",
    "casual": "6c6bf3187e97ae332cb3aa5eca0865ab84aa33dff26d7327bde376d28e9e61c3",
}
_GATES = {"v1": (False, False), "v2": (True, False), "v2_clustered": (True, True)}

_SCORED = [
    {"question": "Why are the footprints on the Moon still there?",
     "answer": "There is no wind there", "difficulty": "medium", "topic": "Moon",
     "possible_answers": None},
    {"question": "Which is bigger?", "answer": "b", "difficulty": "easy",
     "topic": "Animals", "possible_answers": {"a": "Cat", "b": "Elephant"}},
]


def _sha(prompts: list[str]) -> str:
    return hashlib.sha256("\n=====\n".join(sorted(set(prompts))).encode()).hexdigest()


def _scorer_prompts(gate: str, **kw: Any) -> list[str]:
    gate_v2, clustered = _GATES[gate]
    scorer = MultiModelScorer(
        models=[{"provider": "openai", "model": "m", "name": "m"}],
        gate_v2=gate_v2, gate_v2_clustered=clustered,
    )
    prompts: list[str] = []

    async def fake_invoke(model_config, prompt, semaphore):
        prompts.append(prompt)
        return SimpleNamespace(content='{"score": 5, "reasoning": "r"}')

    scorer._invoke = fake_invoke
    for q in _SCORED:
        asyncio.run(scorer.score_question(**q, **kw))
    return prompts


def _casual_prompts(**kw: Any) -> list[str]:
    checker = CasualPlayerChecker(model="m", today=date(2026, 11, 15))
    prompts: list[str] = []

    async def fake_complete(prompt):
        prompts.append(prompt)  # None reply: the check keeps the question

    checker._complete = fake_complete
    for lang in ("en", "sk", "cs", "de"):
        q = Question(id="1", question="Who sang X?", correct_answer="b", topic="music",
                     category="entertainment", difficulty="easy", language=lang,
                     possible_answers={"a": "A", "b": "B"}, source_url=None)
        asyncio.run(checker.check(q, 25, **kw))
    return prompts


# --- 1. adult judging is untouched -------------------------------------------


@pytest.mark.parametrize("gate", list(_GATES))
@pytest.mark.parametrize("kw", [{}, {"audience": None}, {"audience": "adults"}])
def test_adult_judge_prompts_are_byte_identical(gate, kw) -> None:
    assert _sha(_scorer_prompts(gate, **kw)) == ADULT_PROMPT_SHA[gate]


@pytest.mark.parametrize("kw", [{}, {"audience": None}, {"audience": "adults"}])
def test_adult_casual_player_prompt_is_byte_identical(kw) -> None:
    assert _sha(_casual_prompts(**kw)) == ADULT_PROMPT_SHA["casual"]


# --- 2. a child band changes who the judges score for -------------------------


@pytest.mark.parametrize("gate", list(_GATES))
@pytest.mark.parametrize("band", BANDS)
def test_child_band_reframes_every_judge_prompt_for_that_age(gate, band) -> None:
    adult = _scorer_prompts(gate)
    child = _scorer_prompts(gate, audience=band)
    # Same judges, same dimensions, same number of calls: only the framing moves.
    assert len(child) == len(adult)
    lens = audience.judge_lens(band)
    for prompt in child:
        assert f"a child aged {audience.LABELS[band]}" in prompt
        # Placed right after the opening paragraph, which describes the adult
        # player the lens replaces, and before the question and rubric.
        head, rest = prompt.split("\n\n", 1)
        assert rest.startswith(lens)
        assert head.startswith("You are evaluating ONE trivia quiz question")
    # The calibrated rubrics themselves are not rewritten.
    if gate == "v1":
        for spec in SCORING_DIMENSIONS.values():
            assert any(spec["rubric"] in p for p in child)


def test_each_band_gets_its_own_lens() -> None:
    lenses = {audience.judge_lens(b) for b in BANDS}
    assert len(lenses) == 3
    assert "own body" in audience.judge_lens("kids_7_9")


@pytest.mark.parametrize("band", BANDS)
def test_casual_player_judges_a_child_of_the_band(band) -> None:
    prompts = _casual_prompts(audience=band)
    label = audience.LABELS[band]
    assert all(f"a child aged {label}" in p for p in prompts)
    assert not any("adults" in p or "pub-quiz" in p for p in prompts)
    assert "living in Slovakia" in prompts[1]
    # Same JSON contract, so the same parser and floor decide.
    assert all('"casual_correct_pct"' in p for p in prompts)


# --- 3. ScoringStage hands the band to both judges ----------------------------


class _FakeScorer:
    def __init__(self) -> None:
        self.kwargs: list[dict] = []

    async def score_batch(self, payload, **kwargs):
        self.kwargs.append(kwargs)
        verdict = {"scores": {"surprise_delight": 8.0, "answerability": 8.0},
                   "overall_score": 8.0}
        return [
            {"id": q["id"], "model_scores": [
                {**verdict, "model_name": "a"}, {**verdict, "model_name": "b"}]}
            for q in payload
        ]


class _FakeCasual:
    def __init__(self) -> None:
        self.kwargs: list[dict] = []

    async def check(self, q, floor, **kwargs):
        from app.verification.casual_player import CasualVerdict

        self.kwargs.append(kwargs)
        return CasualVerdict(passed=True, pct=80, giveaway=False)


def _q(
    text: str = "Why has nothing erased the astronauts' footprints on the Moon?",
    **kw: Any,
) -> Question:
    base = {
        "id": str(uuid.uuid4()), "question": text, "correct_answer": "There is no wind there",
        "topic": "Moon", "category": "entertainment", "difficulty": "easy",
        "explanation": "Nothing blows the dust away.", "source_url": None,
    }
    base.update(kw)
    return Question(**base)


def _ctx(band: str | None, questions: list[Question], target: int = 10) -> OrderContext:
    ctx = OrderContext(order_id=uuid.uuid4(), prompt="space", language="en",
                       target_count=target, audience=band)
    ctx.questions = questions
    return ctx


class _Sink:
    async def publish(self, *a, **k):
        return None


@pytest.mark.parametrize("band,expected", [
    (None, {}), ("adults", {}), ("kids_7_9", {"audience": "kids_7_9"}),
])
def test_scoring_stage_passes_the_band_only_for_a_child_pack(monkeypatch, band, expected) -> None:
    monkeypatch.setenv("CASUAL_PLAYER_GATE", "shadow")
    scorer, casual = _FakeScorer(), _FakeCasual()
    ctx = _ctx(band, [_q()])
    asyncio.run(ScoringStage(scorer, casual_checker=casual).run(ctx, _Sink()))
    # Adult calls are exactly the pre-#236 calls: no audience keyword at all.
    assert scorer.kwargs == [expected]
    assert casual.kwargs == [expected]
    assert len(ctx.questions) == 1


# --- 4. answer length caps -----------------------------------------------------


def test_moon_footprints_why_answer_fits_7_9_and_10_12_but_not_4_6() -> None:
    # Founder trial 2026-11-15: a good "why" question dropped as answer_too_long.
    q = _q(explanation="There is no wind on the Moon to blow the dust away.")
    assert kids_check.length_violation(q, "kids_7_9") is None
    assert kids_check.length_violation(q, "kids_10_12") is None
    # Preschoolers answer in a word or two (or the parent taps): still tight.
    assert kids_check.length_violation(q, "kids_4_6") == "answer_too_long"
    # And the adult spoken-answer guard downstream does not drop it either.
    assert craft_guards.long_answer_reason(q.correct_answer) is None


def test_band_answer_caps() -> None:
    caps = {b: audience.LIMITS[b].answer_words for b in BANDS}
    assert caps == {"kids_4_6": 2, "kids_7_9": 6, "kids_10_12": 6}
    # A cap above the adult spoken-answer guard would just move the drop there.
    assert max(caps.values()) <= craft_guards._ANSWER_MAX_WORDS


# --- 5. true/false cap -----------------------------------------------------------


def _tf(i: int) -> Question:
    return _q(text=f"Is fact {i} true?", correct_answer="a" if i % 2 else "b",
              possible_answers={"a": "True", "b": "False"}, topic=f"topic {i}")


def _compose(band: str | None, n: int = 10) -> tuple[OrderContext, dict]:
    ctx = _ctx(band, [_tf(i) for i in range(n)], target=n)
    result = asyncio.run(CompositionStage().run(ctx, _Sink()))
    return ctx, result.info


def test_two_option_4_6_pack_is_not_decimated_by_the_tf_cap() -> None:
    ctx, info = _compose("kids_4_6")
    assert len(ctx.questions) == 10 and info["tf_cap_dropped"] == 0
    assert info["tf_cap"] is None


def test_7_9_and_10_12_allow_a_third_of_the_pack_as_true_false() -> None:
    for band in ("kids_7_9", "kids_10_12"):
        ctx, info = _compose(band)
        assert info["tf_cap"] == 3 and len(ctx.questions) == 3


@pytest.mark.parametrize("band", [None, "adults"])
def test_adult_tf_cap_is_unchanged(band) -> None:
    ctx, info = _compose(band)
    assert info["tf_cap"] == 1 and len(ctx.questions) == 1


@pytest.mark.parametrize("band", BANDS)
def test_child_pack_keeps_paid_questions_sharing_the_order_topic_label(band) -> None:
    # Second trial 2026-11-17: "dropped ... topic='LEGO' over per-topic cap 2".
    # The label is the order's own topic, so the cap threw away paid
    # questions without measuring any spread; the sub-theme plan does that.
    # A child pack is always a customer order (the worker); since 2026-11-18
    # no customer pack has a topic cap (adult cases: test_composition.py).
    qs = [_q(text=f"Which LEGO fact {i}?", topic="LEGO") for i in range(5)]
    ctx = _ctx(band, qs, target=10)
    info = asyncio.run(CompositionStage(customer_order=True).run(ctx, _Sink())).info
    assert len(ctx.questions) == 5
    assert info["topic_cap"] is None and info["topic_cap_dropped"] == 0


# --- 6. the kids prompt steers to the child's world -----------------------------


def test_kids_prompt_steers_to_the_childs_world_and_keeps_the_rules() -> None:
    from pathlib import Path

    text = (Path(__file__).resolve().parents[1] / "prompts"
            / "question_generation_direct_kids.md").read_text()
    assert "their own body" in text and "try or check right away" in text
    assert "gross-but-harmless" in text
    assert "On Venus a day lasts longer than its year" in text  # the anti-example
    # Safety rules and the founder's riddle ban survive.
    for rule in ("NO violence, weapons, war", "NO drugs, alcohol", "NO horror",
                 "NO politics, religion", 'No "what am I" / "who am I" riddles'):
        assert rule in text
    # The safety judge must not reject the humour the prompt now asks for.
    assert "gross-out facts" in kids_check._PROMPT


def test_kids_prompt_asks_for_one_local_name_and_local_punctuation(monkeypatch) -> None:
    # Second trial 2026-11-17 (sk): "Hedwigu ... Hedwiga" in one question and
    # "Hedviga" (the Slovak books' name) in another; "viac, či menej?" with an
    # English-style comma. No language check runs on custom-pack text, so the
    # generation call that writes the Slovak must carry the rule, and it must
    # reach the rendered prompt a child-band order sends.
    from app.generation import advanced_generator
    from app.generation.advanced_generator import AdvancedQuestionGenerator

    monkeypatch.setenv("OPENAI_API_KEY", "test-key-not-used")
    gen =AdvancedQuestionGenerator(
        generation_model="gpt-4o", critique_model="gpt-4o-mini", prompt_version="direct_v1"
    )
    token = advanced_generator._ORDER_AUDIENCE.set("kids_10_12")
    try:
        prompt, *_ = gen._build_batch_prompt(
            count=3, difficulty="medium", topics=["Harry Potter"], categories=None,
            question_type="text", excluded_topics=None, avoid_questions=None,
            user_bad_examples=None,
        )
    finally:
        advanced_generator._ORDER_AUDIENCE.reset(token)
    assert "**One name, one spelling.**" in prompt
    assert '"Hedviga"' in prompt and "official translation" in prompt
    assert "every question of the pack" in prompt
    assert 'no comma before "či"' in prompt
