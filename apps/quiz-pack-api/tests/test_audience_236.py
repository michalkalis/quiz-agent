"""#236 236.1 — age band on a custom pack order.

Why these matter: a parent who picks "7-9" must get a pack written for a
child of that age and checked by the server, not an adult pack with a nicer
prompt; and every order without the choice (every shipped build) must get
exactly today's adult pack. A judge outage must end the order (refund) rather
than let top-up rounds buy generation runs whose output is thrown away.
"""

from __future__ import annotations

import asyncio
import uuid
from types import SimpleNamespace
from typing import Any

import pytest
from app import audience, kids_check, topic_check
from app.api.v1.orders import CreateOrderRequest, TopicCheckRequest
from app.generation import advanced_generator
from app.generation.advanced_generator import (
    KIDS_PROMPT_VERSION,
    AdvancedQuestionGenerator,
)
from app.orchestrator import OrderContext
from app.orchestrator.pack_generator import PackGenerator
from app.orchestrator.stages.generation import GenerationStage
from app.worker.failure_class import non_retryable_reason
from pydantic import ValidationError
from quiz_shared.models.question import Question


@pytest.fixture(autouse=True)
def _stub_openai_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OPENAI_API_KEY", "test-key-not-used")


def _q(idx: int, text: str = "Which animal says moo?", **kw: Any) -> Question:
    base = {
        "id": str(uuid.uuid4()),
        "question": text,
        "correct_answer": "cow",
        "topic": "animals",
        "category": "general",
        "difficulty": "easy",
        "explanation": "Cows moo to talk to each other.",
        "source_url": None,
    }
    base.update(kw)
    return Question(**base)


# --- 1. the order field ------------------------------------------------------


def _order_body(**extra: Any) -> dict:
    return {
        "transaction_id": "t",
        "product_id": "pack_10",
        "prompt": "space",
        "language": "en",
        "target_count": 10,
        **extra,
    }


def test_order_without_audience_is_an_adult_order() -> None:
    # Every shipped build omits the field; it must stay optional and mean adults.
    assert CreateOrderRequest(**_order_body()).audience is None
    assert TopicCheckRequest(prompt="x", language="en").audience is None
    assert not audience.is_child(None) and not audience.is_child("adults")


@pytest.mark.parametrize("value", ["kids_4_6", "kids_7_9", "kids_10_12", "adults"])
def test_order_accepts_the_four_audiences(value) -> None:
    assert CreateOrderRequest(**_order_body(audience=value)).audience == value


@pytest.mark.parametrize("value", ["kids", "8", "kids_13_15", ""])
def test_order_rejects_an_unknown_audience(value) -> None:
    # The DB check constraint would 500 after payment; reject at validation.
    with pytest.raises(ValidationError):
        CreateOrderRequest(**_order_body(audience=value))


def test_audience_is_not_a_required_request_field_in_the_contract() -> None:
    # CI's OpenAPI compat check fails a new required request field: live builds.
    schema = CreateOrderRequest.model_json_schema()
    assert "audience" not in schema.get("required", [])


# --- 2. the kids prompt ------------------------------------------------------


def _build(gen: AdvancedQuestionGenerator, band: str | None, difficulty="medium"):
    token = advanced_generator._ORDER_AUDIENCE.set(band)
    try:
        return gen._build_batch_prompt(
            count=5,
            difficulty=difficulty,
            topics=["space"],
            categories=None,
            question_type="text",
            excluded_topics=None,
            avoid_questions=None,
            user_bad_examples=None,
        )
    finally:
        advanced_generator._ORDER_AUDIENCE.reset(token)


@pytest.fixture
def gen() -> AdvancedQuestionGenerator:
    return AdvancedQuestionGenerator(
        generation_model="gpt-4o", critique_model="gpt-4o-mini", prompt_version="direct_v1"
    )


def test_adult_prompt_is_unchanged(gen, monkeypatch) -> None:
    # The examples are sampled per call; pin them so two renders compare.
    monkeypatch.setattr(
        "app.generation.prompt_builder.load_gold_standard", lambda **kw: "EX"
    )
    plain, version, *_ = _build(gen, None)
    adults, *_ = _build(gen, "adults")
    direct = gen.prompt_builder.build_prompt(
        count=5, difficulty="medium", topics=["space"], categories=None,
        question_type="text", excluded_topics=None, avoid_questions=None,
        user_bad_examples=None, generation_model=gen.generation_model,
        mcq_patterns_section="",
    )
    assert version == "direct_v1"
    assert plain == adults == direct
    assert "broad international adult audience" in plain
    assert "a non-native-English adult player" in plain


@pytest.mark.parametrize("band", ["kids_4_6", "kids_7_9", "kids_10_12"])
def test_child_band_uses_the_kids_prompt(gen, band) -> None:
    prompt, version, use_open, use_fact_first = _build(gen, band)
    assert version == KIDS_PROMPT_VERSION
    assert not use_open and not use_fact_first
    assert "adult audience" not in prompt
    assert f"Age band: {audience.LABELS[band]} years" in prompt
    # Content rules and the direct prompt's quality rules both survive.
    assert "NO violence, weapons, war" in prompt
    assert "Leave `source_url` and `source_excerpt` empty" in prompt
    assert "language_dependent: true" in prompt
    # The prompt quotes the same caps the server enforces.
    assert f"at most {audience.LIMITS[band].question_words} words" in prompt
    assert "{" not in prompt.split("## Response Format")[0]


def test_band_and_difficulty_are_separate_axes(gen) -> None:
    # "hard" for 4-6 must stay a 4-6 question, not become a 10-12 one.
    hard_small, *_ = _build(gen, "kids_4_6", difficulty="hard")
    assert "Age band: 4-6 years" in hard_small
    assert "every question in this batch must be hard" in hard_small
    assert "a child aged 4-6 (difficulty is relative to this age band" in hard_small
    assert "non-native-English adult player" not in hard_small
    assert "Yes" in hard_small and "exactly two" in hard_small


@pytest.mark.asyncio
async def test_generate_questions_scopes_the_band_to_its_call(gen) -> None:
    # The band rides a ContextVar like the order brief: it must not leak into
    # the next order the same generator writes.
    seen: list[str] = []

    async def fake_invoke(messages):
        seen.append(messages[0].content)
        return SimpleNamespace(content='{"questions": []}')

    gen.generation_llm = SimpleNamespace(ainvoke=fake_invoke, temperature=0.8)
    await gen.generate_questions(count=2, enable_best_of_n=False, audience="kids_7_9")
    await gen.generate_questions(count=2, enable_best_of_n=False)
    assert "Age band: 7-9 years" in seen[0]
    assert "Age band" not in seen[1] and "adult audience" in seen[1]


# --- 3. the post-generation kids check ---------------------------------------


class _Judge:
    def __init__(self, replies: list[Any]) -> None:
        self.replies = list(replies)
        self.prompts: list[str] = []

    async def ainvoke(self, prompt):
        self.prompts.append(prompt)
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return SimpleNamespace(content=reply, response_metadata={})


@pytest.fixture
def judge(monkeypatch):
    def install(*replies):
        client = _Judge(list(replies))
        monkeypatch.setattr(kids_check.llm_factory, "chat_available", lambda m: True)
        monkeypatch.setattr(kids_check.llm_factory, "chat_model", lambda m, **k: client)
        monkeypatch.setattr(kids_check.llm_factory, "message_text", lambda r: r.content)
        monkeypatch.setattr(kids_check, "RETRY_DELAY_SECONDS", 0)
        return client

    return install


def test_unsuitable_unsure_and_missing_verdicts_drop_the_question(judge) -> None:
    # Fail closed: only a clear "ok" keeps a question in a child's pack.
    client = judge("1: ok\n2: unsuitable\n3: unsure")
    qs = [_q(i) for i in range(4)]
    kept, dropped = asyncio.run(kids_check.filter_questions(qs, "kids_7_9"))
    assert kept == [qs[0]]
    assert dropped == {"length": 0, "theme": 3}
    assert "aged 7-9" in client.prompts[0]


def test_over_long_questions_drop_without_a_judge_call(judge) -> None:
    client = judge("1: ok")
    long_q = _q(0, text=" ".join(["word"] * (audience.LIMITS["kids_4_6"].question_words + 1)))
    long_option = _q(1, possible_answers={"a": "a very long option text", "b": "no"},
                     correct_answer="a")
    ok = _q(2)
    kept, dropped = asyncio.run(
        kids_check.filter_questions([long_q, long_option, ok], "kids_4_6")
    )
    assert kept == [ok]
    assert dropped == {"length": 2, "theme": 0}
    assert len(client.prompts) == 1 and long_q.question not in client.prompts[0]


def test_judge_outage_retries_then_fails_the_order(judge) -> None:
    # An outage is not a verdict: retried, then raised as a non-retryable
    # failure so the order ends failed + refundable instead of topping up.
    client = judge(RuntimeError("down"), "I cannot help", RuntimeError("down"))
    with pytest.raises(kids_check.KidsJudgeUnavailable) as exc:
        asyncio.run(kids_check.filter_questions([_q(0)], "kids_10_12"))
    assert len(client.prompts) == kids_check.ATTEMPTS
    assert non_retryable_reason(exc.value) is not None
    wrapped = RuntimeError("stage failed")
    wrapped.__cause__ = exc.value
    assert non_retryable_reason(wrapped) is not None


def test_judge_recovers_on_a_retry(judge) -> None:
    judge(RuntimeError("blip"), "1: ok")
    kept, _ = asyncio.run(kids_check.filter_questions([_q(0)], "kids_7_9"))
    assert len(kept) == 1


def test_no_provider_is_an_outage_not_an_empty_pass(monkeypatch) -> None:
    monkeypatch.setattr(kids_check.llm_factory, "chat_available", lambda m: False)
    with pytest.raises(kids_check.KidsJudgeUnavailable):
        asyncio.run(kids_check.filter_questions([_q(0)], "kids_7_9"))


# --- GenerationStage wiring ---------------------------------------------------


class _FakeGenerator:
    def __init__(self, questions: list[Question]) -> None:
        self.questions = questions
        self.calls: list[dict[str, Any]] = []

    async def generate_questions(self, **kwargs: Any) -> list[Question]:
        self.calls.append(kwargs)
        return list(self.questions)


class _Sink:
    async def start_step(self, *a, **k):
        return 0

    async def finish_step(self, *a, **k):
        return None

    async def publish(self, *a, **k):
        return None


def _ctx(band: str | None) -> OrderContext:
    return OrderContext(
        order_id=uuid.uuid4(), prompt="space", language="en", target_count=10,
        audience=band, direct_generation=True,
    )


def test_adult_order_never_meets_the_kids_check(monkeypatch) -> None:
    async def boom(*a, **k):
        raise AssertionError("kids check must not run for an adult order")

    monkeypatch.setattr(kids_check, "filter_questions", boom)
    monkeypatch.setenv("GEN_HOUSE_STYLE", "1")
    fake = _FakeGenerator([_q(0)])
    for band in (None, "adults"):
        ctx = _ctx(band)
        asyncio.run(GenerationStage(fake).run(ctx, _Sink()))
        assert len(ctx.questions) == 1
    # The generator call is the same as before #236: no audience kwarg, the
    # open slice and the house style intact.
    assert all("audience" not in c for c in fake.calls)
    assert all(c["open_count"] == 1 for c in fake.calls)
    assert all("HOUSE STYLE" in c["order_brief"] for c in fake.calls)


def test_child_order_is_checked_and_written_without_adult_parts(monkeypatch) -> None:
    seen: list[str] = []

    async def fake_filter(questions, band):
        seen.append(band)
        return questions[:1], {"length": 0, "theme": len(questions) - 1}

    monkeypatch.setattr(kids_check, "filter_questions", fake_filter)
    monkeypatch.setenv("GEN_HOUSE_STYLE", "1")
    fake = _FakeGenerator([_q(0), _q(1)])
    ctx = _ctx("kids_7_9")
    result = asyncio.run(GenerationStage(fake).run(ctx, _Sink()))
    assert seen == ["kids_7_9"]
    assert len(ctx.questions) == 1
    assert result.info["dropped_kids_theme"] == 1
    call = fake.calls[0]
    assert call["audience"] == "kids_7_9"
    assert call["open_count"] == 0  # the open slice is the adult puzzle prompt
    assert "HOUSE STYLE" not in call["order_brief"]  # adults' taste brief


@pytest.mark.parametrize("mode", [None, "grounded"])
def test_child_order_always_runs_direct(mode) -> None:
    # Only the direct path has a kids prompt; grounded would use the adult one.
    order = SimpleNamespace(
        id=uuid.uuid4(), prompt="space", language="en", target_count=10,
        category=None, theme=None, difficulty=None, product_id="pack_10",
        generation_mode=mode, audience="kids_4_6",
    )

    class _Stop(Exception):
        pass

    class _Sourcing:
        name = "sourcing"

        async def run(self, ctx, sink):
            assert ctx.direct_generation is True
            assert ctx.audience == "kids_4_6"
            raise _Stop

    gen_ = PackGenerator(stages=[_Sourcing()], sink_factory=lambda _id: _FailSink())
    with pytest.raises(_Stop):
        asyncio.run(gen_.run(order))


class _FailSink(_Sink):
    pass


# --- 4. topic check child tier ------------------------------------------------


@pytest.fixture
def topic_fake(monkeypatch):
    def install(content="ok", exc=None):
        prompts: list[str] = []

        class _Client:
            async def ainvoke(self, prompt):
                prompts.append(prompt)
                if exc:
                    raise exc
                return SimpleNamespace(content=content, response_metadata={})

        monkeypatch.setattr(topic_check.llm_factory, "chat_available", lambda m: True)
        monkeypatch.setattr(topic_check.llm_factory, "chat_model", lambda m, **k: _Client())
        monkeypatch.setattr(topic_check.llm_factory, "message_text", lambda r: r.content)
        return prompts

    return install


def test_borderline_topic_is_blocked_for_a_child_band(topic_fake) -> None:
    topic_fake("softened")
    assert asyncio.run(topic_check.check_topic("famous crimes", audience="kids_7_9")) == (
        "blocked", False,
    )


def test_adult_tier_is_unchanged(topic_fake) -> None:
    prompts = topic_fake("softened")
    assert asyncio.run(topic_check.check_topic("famous crimes")) == ("softened", False)
    assert asyncio.run(topic_check.check_topic("famous crimes", audience="adults")) == (
        "softened", False,
    )
    assert "CHILDREN" not in prompts[0] and prompts[0] == prompts[1]


def test_child_tier_names_the_band_and_stays_fail_open(topic_fake) -> None:
    prompts = topic_fake("ok")
    asyncio.run(topic_check.check_topic("space", audience="kids_4_6"))
    assert "CHILDREN AGED 4-6" in prompts[0]
    topic_fake(exc=RuntimeError("down"))
    assert asyncio.run(topic_check.check_topic("space", audience="kids_4_6")) == ("ok", True)
