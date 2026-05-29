"""Unit tests for GenerationStage (issue #36 task 2.5).

Why these scenarios:

- `test_post_processes_questions_with_order_metadata`: `prompt_seed` is
  what groups a regenerated pack on the same prompt — without it,
  downstream cross-pack analytics (D7) sees unrelated rows. `language`
  is what voice-quiz reads (apps/quiz-agent retrieval); a None here
  makes the question invisible to language-filtered queries.
- `test_marks_pipeline_fact_first_when_facts_present`: F8 source-quality
  enforcement (task 2.15) relies on provenance carrying through — the
  audit trail must record that SourcingStage fed Generation.
- `test_carries_source_url_and_excerpt_from_facts`: the e2e test in
  task 2.11 asserts every persisted Question has a non-null
  `source_url`. The generator may or may not populate it; the stage
  backfills from the Fact references so the F8 invariant holds even
  when the LLM forgets to attribute.
- `test_calls_generator_with_target_count_and_facts`: pins the wrap's
  contract with `AdvancedQuestionGenerator` — if the generator's
  constructor or `generate_questions` kwargs shift in a later PR,
  this test breaks loudly (R11 in the risk register).
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest

from app.orchestrator import OrderContext
from app.orchestrator.stages.generation import GenerationStage, _compute_prompt_seed
from app.sourcing.models import Fact
from quiz_shared.models.question import GenerationProvenance, Question


class _RecordingSink:
    def __init__(self) -> None:
        self.events: list[tuple[str, str, Any]] = []
        self._next_id = 0

    async def start_step(self, step: str, info: Any = None) -> int:
        eid = self._next_id
        self._next_id += 1
        self.events.append(("start", step, info))
        return eid

    async def finish_step(self, step: str, event_id: int, info: Any = None) -> None:
        self.events.append(("finish", step, info))

    async def publish(
        self, event_id: int, step: str, progress: int, info: Any = None
    ) -> None:
        self.events.append(("publish", step, info))


class _FakeGenerator:
    def __init__(self, questions: list[Question]) -> None:
        self._questions = questions
        self.calls: list[dict[str, Any]] = []

    async def generate_questions(self, **kwargs: Any) -> list[Question]:
        self.calls.append(kwargs)
        return self._questions


def _stub_question(idx: int, **overrides: Any) -> Question:
    base: dict[str, Any] = dict(
        id=f"q_{idx}",
        question=f"stub question {idx}",
        correct_answer="answer",
        topic="General",
        category="general",
        difficulty="medium",
    )
    base.update(overrides)
    return Question(**base)


def _make_ctx(
    target_count: int = 3,
    facts: list[Fact] | None = None,
    **kwargs: Any,
) -> OrderContext:
    ctx = OrderContext(
        order_id=uuid.uuid4(),
        prompt=kwargs.get("prompt", "famous capitals"),
        language=kwargs.get("language", "sk"),
        target_count=target_count,
        category=kwargs.get("category", "geography"),
        theme=kwargs.get("theme"),
    )
    if facts is not None:
        ctx.facts = facts
    return ctx


@pytest.mark.asyncio
async def test_post_processes_questions_with_order_metadata() -> None:
    questions = [_stub_question(i) for i in range(3)]
    gen = _FakeGenerator(questions)
    stage = GenerationStage(gen)  # type: ignore[arg-type]
    facts = [
        Fact(text=f"t{i}", source_url=f"https://ex/{i}", excerpt=f"e{i}")
        for i in range(3)
    ]
    ctx = _make_ctx(target_count=3, facts=facts)

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    expected_seed = _compute_prompt_seed(
        ctx.prompt, ctx.language, ctx.category, ctx.theme
    )
    assert len(ctx.questions) == 3
    assert all(q.prompt_seed == expected_seed for q in ctx.questions)
    assert all(q.language == "sk" for q in ctx.questions)


@pytest.mark.asyncio
async def test_marks_pipeline_fact_first_when_facts_present() -> None:
    questions = [_stub_question(i) for i in range(2)]
    gen = _FakeGenerator(questions)
    stage = GenerationStage(gen)  # type: ignore[arg-type]
    facts = [Fact(text="paris is the capital", source_url="https://ex/1")]
    ctx = _make_ctx(target_count=2, facts=facts)

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert all(q.generation_metadata is not None for q in ctx.questions)
    assert all(
        q.generation_metadata.pipeline == "fact_first" for q in ctx.questions
    )


@pytest.mark.asyncio
async def test_preserves_existing_provenance_fields_when_marking_pipeline() -> None:
    """The pipeline=='fact_first' update must not clobber other provenance
    set by `AdvancedQuestionGenerator` (e.g. `model`, `critique_score`)."""
    pre = GenerationProvenance(
        model="gpt-4o", provider="openai", critique_score=8.5
    )
    questions = [_stub_question(0, generation_metadata=pre)]
    gen = _FakeGenerator(questions)
    stage = GenerationStage(gen)  # type: ignore[arg-type]
    # F8 (task 2.15): fact needs `source_url` so the stage's fallback can
    # backfill the question — otherwise the F8 invariant assert trips and
    # this test (which exercises provenance preservation, not attribution)
    # never reaches its assertions.
    ctx = _make_ctx(target_count=1, facts=[Fact(text="x", source_url="https://ex/x")])

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    meta = ctx.questions[0].generation_metadata
    assert meta.pipeline == "fact_first"
    assert meta.model == "gpt-4o"
    assert meta.critique_score == 8.5


@pytest.mark.asyncio
async def test_carries_source_url_and_excerpt_from_facts() -> None:
    questions = [_stub_question(0)]
    gen = _FakeGenerator(questions)
    stage = GenerationStage(gen)  # type: ignore[arg-type]
    facts = [
        Fact(
            text="Paris is the capital of France.",
            source_url="https://wiki/paris",
            excerpt="Paris is the capital",
        )
    ]
    ctx = _make_ctx(target_count=1, facts=facts)

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert ctx.questions[0].source_url == "https://wiki/paris"
    assert ctx.questions[0].source_excerpt == "Paris is the capital"


@pytest.mark.asyncio
async def test_does_not_overwrite_question_supplied_source_url() -> None:
    """If the generator already attributed a source, the stage must not
    replace it — preserves whatever finer-grained linkage the prompt found."""
    questions = [
        _stub_question(
            0,
            source_url="https://generator/attributed",
            source_excerpt="from prompt",
        )
    ]
    gen = _FakeGenerator(questions)
    stage = GenerationStage(gen)  # type: ignore[arg-type]
    facts = [Fact(text="t", source_url="https://fact/url", excerpt="from fact")]
    ctx = _make_ctx(target_count=1, facts=facts)

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert ctx.questions[0].source_url == "https://generator/attributed"
    assert ctx.questions[0].source_excerpt == "from prompt"


@pytest.mark.asyncio
async def test_normalises_non_uuid_question_ids() -> None:
    """AdvancedQuestionGenerator returns questions with `q_<hex>` ids (Phase 1
    legacy from `app/generation/storage.py`). PersistStage's `_coerce_uuid`
    refuses non-UUID strings on purpose, so the stage must replace those
    legacy ids with real UUIDs at the boundary — otherwise the e2e flow
    fails on the first persist call.
    """
    questions = [_stub_question(0, id="q_abc123def456"), _stub_question(1)]
    gen = _FakeGenerator(questions)
    stage = GenerationStage(gen)  # type: ignore[arg-type]
    facts = [Fact(text="t", source_url="https://ex/1")]
    ctx = _make_ctx(target_count=2, facts=facts)

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    for q in ctx.questions:
        uuid.UUID(q.id)  # raises if not a valid UUID


@pytest.mark.asyncio
async def test_raises_when_no_question_has_source_url() -> None:
    """F8 (task 2.15) requires every persisted question to have `source_url`.

    The wrap's fallback backfills questions from the first attributed
    fact — but when no fact carries a URL (e.g. an OpenTriviaDB-only run
    upstream of full sourcing rules), the gap must fail loudly so the
    pack never reaches PersistStage with null attribution.
    """
    questions = [_stub_question(i) for i in range(3)]
    gen = _FakeGenerator(questions)
    stage = GenerationStage(gen)  # type: ignore[arg-type]
    facts = [Fact(text=f"t{i}") for i in range(5)]  # no source_url anywhere
    ctx = _make_ctx(target_count=3, facts=facts)

    with pytest.raises(ValueError, match="F8 violated"):
        await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]


@pytest.mark.asyncio
async def test_drops_questions_violating_answer_brevity() -> None:
    """Issue #42 task 42.7 — post-generation fail-loud validator.

    Rules enforced (mirror the v3/v2 prompt constraints from 42.5):
    `correct_answer` ≤ 10 words and free of em/en-dash, "because",
    "namely", "i.e.", "which means". Violations are dropped and the
    count is surfaced via `StageResult.info["dropped_quality"]` so
    SSE clients and the audit log see the filter activity (same
    shape as DedupStage's `dropped` field).
    """
    questions = [
        _stub_question(0, correct_answer="Paris"),  # OK
        _stub_question(
            1,
            correct_answer="Paris — the capital of France since the tenth century",
        ),  # em-dash + over cap → drop
        _stub_question(2, correct_answer="Jupiter"),  # OK
        _stub_question(
            3,
            correct_answer="False because the wall is not actually visible from orbit",
        ),  # "because" tail → drop
        _stub_question(4, correct_answer=["Mercury", "Venus"]),  # OK (list, short)
    ]
    gen = _FakeGenerator(questions)
    stage = GenerationStage(gen)  # type: ignore[arg-type]
    facts = [Fact(text="t", source_url="https://ex/1")]
    ctx = _make_ctx(target_count=5, facts=facts)

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert len(ctx.questions) == 3
    kept_ids = {q.question for q in ctx.questions}
    assert kept_ids == {"stub question 0", "stub question 2", "stub question 4"}
    assert result.info["dropped_quality"] == 2
    assert result.info["questions"] == 3


@pytest.mark.asyncio
async def test_tags_mcq_type_and_drops_when_options_missing() -> None:
    """Issue #42 task 42.9a — post-generation MCQ type tagging.

    The LLM picks the reasoning pattern; some patterns
    (`true_false`, `odd_one_out`, `comparison_bet_older_larger`,
    `year_guess`) are inherently multiple-choice and must surface as
    `type="text_multichoice"` so iOS `MCQOptionPicker` activates and
    the evaluator's `possible_answers` fast-path routes correctly.

    Fail-loud contract: when the pattern requires MCQ but the generator
    didn't emit `possible_answers`, drop the question rather than ship a
    half-built MCQ. Surface the drop count via
    `StageResult.info["dropped_mcq_missing_options"]` so audit / SSE
    sees the gap (same shape as `dropped_quality`).
    """
    questions = [
        _stub_question(
            0,
            correct_answer="a",
            possible_answers={"a": "True", "b": "False"},
            generation_metadata=GenerationProvenance(reasoning_pattern="true_false"),
        ),  # MCQ pattern + options → tag text_multichoice
        _stub_question(
            1,
            correct_answer="b",
            possible_answers={"a": "True", "b": "False"},
            generation_metadata=GenerationProvenance(reasoning_pattern="true_false"),
        ),  # MCQ pattern + options → tag text_multichoice
        _stub_question(
            2,
            correct_answer="True",
            generation_metadata=GenerationProvenance(reasoning_pattern="true_false"),
        ),  # MCQ pattern but NO options → drop
        _stub_question(
            3,
            correct_answer="Paris",
            generation_metadata=GenerationProvenance(reasoning_pattern="fact_recall"),
        ),  # non-MCQ pattern → keep as text
    ]
    gen = _FakeGenerator(questions)
    stage = GenerationStage(gen)  # type: ignore[arg-type]
    facts = [Fact(text="t", source_url="https://ex/1")]
    ctx = _make_ctx(target_count=4, facts=facts)

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert len(ctx.questions) == 3
    types_by_qtext = {q.question: q.type for q in ctx.questions}
    assert types_by_qtext == {
        "stub question 0": "text_multichoice",
        "stub question 1": "text_multichoice",
        "stub question 3": "text",
    }
    assert result.info["dropped_mcq_missing_options"] == 1
    assert result.info["dropped_quality"] == 0
    assert result.info["questions"] == 3


@pytest.mark.asyncio
async def test_calls_generator_with_target_count_and_facts() -> None:
    questions = [_stub_question(i) for i in range(5)]
    gen = _FakeGenerator(questions)
    stage = GenerationStage(gen)  # type: ignore[arg-type]
    # F8 (task 2.15): at least one fact must carry `source_url` so the
    # fallback can backfill all questions and the F8 invariant assert
    # doesn't trip — this test pins the generator-kwargs contract, not
    # attribution.
    facts = [Fact(text=f"t{i}", source_url=f"https://ex/{i}") for i in range(20)]
    ctx = _make_ctx(target_count=5, facts=facts, category="science", theme="space")

    await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert gen.calls[0]["count"] == 5
    assert gen.calls[0]["source_facts"] == facts
    assert gen.calls[0]["topics"] == ["science", "space"]
    assert gen.calls[0]["categories"] == ["science"]
