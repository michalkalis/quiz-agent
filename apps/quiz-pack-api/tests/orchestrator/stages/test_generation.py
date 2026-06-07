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
async def test_logical_puzzle_persists_without_source_url() -> None:
    """Issue #46 task 46.B4 — a pure lateral puzzle (``verification_mode``
    == "logical") is tagged ``pipeline == "logical_puzzle"`` and exempted
    from F8: it is invented, has no web source, and ships with
    ``source_url = null`` (D4/D5). Without the exemption the F8 invariant
    would reject it for lacking attribution.
    """
    questions = [
        _stub_question(
            0,
            correct_answer="The candle",
            generation_metadata=GenerationProvenance(
                reasoning_pattern="lateral_thinking"
            ),
        )
    ]
    gen = _FakeGenerator(questions)
    stage = GenerationStage(gen)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=1, facts=[])  # no facts → no source_url backfill

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    assert len(ctx.questions) == 1
    q = ctx.questions[0]
    assert q.source_url is None
    assert q.generation_metadata.pipeline == "logical_puzzle"
    assert result.info["questions"] == 1


@pytest.mark.asyncio
async def test_factual_question_without_source_url_still_fails_f8() -> None:
    """Issue #46 task 46.B4 — the F8 relaxation is keyed strictly on the
    ``logical_puzzle`` marker. A factual question (any non-logical pattern)
    with no ``source_url`` must still fail loudly so the relaxation can never
    mask an unsourced fact (R3).
    """
    questions = [
        _stub_question(
            0,
            correct_answer="Paris",
            generation_metadata=GenerationProvenance(
                reasoning_pattern="fact_recall"
            ),
        )
    ]
    gen = _FakeGenerator(questions)
    stage = GenerationStage(gen)  # type: ignore[arg-type]
    ctx = _make_ctx(target_count=1, facts=[])

    with pytest.raises(ValueError, match="F8 violated"):
        await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]


@pytest.mark.asyncio
async def test_normalizes_then_drops_violating_answers() -> None:
    """Issue #46 task 46.A2 — post-generation **normalize-then-drop**.

    Supersedes the old drop-only behaviour (42.7). A verbose
    `correct_answer` with a clean short head before an unambiguous tail
    marker (em/en-dash, "because", "while", …) is *split*: the head stays
    in `correct_answer`, the tail moves to `explanation` so the context is
    preserved rather than thrown away (the audit found 96% of "bad"
    answers were short answers written verbosely). A question is dropped
    only when no recoverable short head exists. Counts surface via
    `StageResult.info` so SSE clients + the audit log see the activity.
    """
    questions = [
        _stub_question(0, correct_answer="Paris"),  # OK → keep untouched
        _stub_question(
            1,
            correct_answer="Selective Availability — switched off in 2000 by Clinton",
        ),  # GPS audit example: em-dash → normalize to head
        _stub_question(2, correct_answer="Jupiter"),  # OK → keep
        _stub_question(
            3,
            correct_answer="False because the wall is not actually visible from orbit",
        ),  # "because" tail → normalize to "False"
        _stub_question(4, correct_answer=["Mercury", "Venus"]),  # OK (list, short)
        _stub_question(
            5,
            correct_answer="A lush green landscape with flowing rivers, lakes and abundant grazing wildlife",
        ),  # Sahara audit example: comma-only, over cap, no head → DROP
    ]
    gen = _FakeGenerator(questions)
    stage = GenerationStage(gen)  # type: ignore[arg-type]
    facts = [Fact(text="t", source_url="https://ex/1")]
    ctx = _make_ctx(target_count=6, facts=facts)

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    by_text = {q.question: q for q in ctx.questions}
    assert set(by_text) == {
        "stub question 0",
        "stub question 1",
        "stub question 2",
        "stub question 3",
        "stub question 4",
    }
    # Normalized heads replace the verbose answer; the tail lands in explanation.
    assert by_text["stub question 1"].correct_answer == "Selective Availability"
    assert "switched off in 2000" in by_text["stub question 1"].explanation
    assert by_text["stub question 3"].correct_answer == "False"
    assert "because" in by_text["stub question 3"].explanation
    # Untouched short answers keep an empty explanation.
    assert by_text["stub question 0"].correct_answer == "Paris"
    assert result.info["normalized_quality"] == 2
    assert result.info["dropped_quality"] == 1  # Sahara example, no short head
    assert result.info["questions"] == 5


class _FakeNormalizer:
    """Stand-in AnswerNormalizer: splits a known answer, drops the rest."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, str]] = []

    async def normalize(self, question: str, answer: str):
        from app.generation.answer_normalizer import NormalizedAnswer

        self.calls.append((question, answer))
        if answer.startswith("A lush green landscape"):
            return NormalizedAnswer(
                head="Grassland/savanna",
                explanation="A lush green landscape with rivers and lakes.",
            )
        return None  # indivisible / low-confidence → caller drops


@pytest.mark.asyncio
async def test_llm_normalizer_recovers_comma_tailed_remainder() -> None:
    """Issue #46 task 46.A2b — the comma-tailed over-cap remainder that the
    deterministic splitter (46.A2) leaves untouched is routed to the injected
    LLM normalizer. A recoverable head is normalized (Sahara example); an
    indivisible/low-confidence answer still drops. Without a normalizer (46.A2
    behaviour) both would drop — this pins the new fallback wiring.
    """
    questions = [
        _stub_question(0, correct_answer="Paris"),  # OK → keep untouched
        _stub_question(
            1,
            correct_answer="A lush green landscape with flowing rivers, lakes and grazing wildlife",
        ),  # Sahara: comma-only over cap → LLM normalizes to head
        _stub_question(
            2,
            correct_answer="A rambling unverifiable musing, with no canonical core at all here",
        ),  # comma-only over cap, normalizer returns None → DROP
    ]
    gen = _FakeGenerator(questions)
    normalizer = _FakeNormalizer()
    stage = GenerationStage(gen, answer_normalizer=normalizer)  # type: ignore[arg-type]
    facts = [Fact(text="t", source_url="https://ex/1")]
    ctx = _make_ctx(target_count=3, facts=facts)

    result = await stage.run(ctx, sink=_RecordingSink())  # type: ignore[arg-type]

    by_text = {q.question: q for q in ctx.questions}
    assert set(by_text) == {"stub question 0", "stub question 1"}
    assert by_text["stub question 1"].correct_answer == "Grassland/savanna"
    assert "lush green landscape" in by_text["stub question 1"].explanation
    assert result.info["normalized_quality"] == 1
    assert result.info["dropped_quality"] == 1
    # Only the two over-cap remainders reach the normalizer, not "Paris".
    assert len(normalizer.calls) == 2


@pytest.mark.parametrize(
    "answer,expected",
    [
        # Splits: clean head before an unambiguous marker.
        (
            "Selective Availability — switched off in 2000 by Clinton",
            ("Selective Availability", "switched off in 2000 by Clinton"),
        ),
        ("True while the others are prime numbers", ("True", "while the others are prime numbers")),
        # No split: comma is structural in legitimate short answers and must
        # NOT be split by the deterministic pass (it defers to the LLM fallback).
        ("Tokyo, Japan", None),
        ("December 7, 1941", None),
        ("salt, pepper, flour", None),
        # No split: comma-only verbose answer has no unambiguous marker.
        ("A lush green landscape with rivers, lakes and wildlife", None),
        # No split: marker present but the head is itself over the cap → no
        # recoverable canonical answer.
        (
            "The very long winding country road that goes absolutely nowhere at all — because reasons",
            None,
        ),
    ],
)
def test_split_answer_head_deterministic(answer, expected) -> None:
    """46.A2 — the deterministic splitter only fires on unambiguous markers
    and never on a bare comma (the comma false-positive guard)."""
    from app.orchestrator.stages.generation import _split_answer_head

    assert _split_answer_head(answer) == expected


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
    # Issue #42 task 42.9b — MCQ patterns must reach the generator so the
    # prompt's `{mcq_patterns_section}` is non-empty. Loose-set comparison
    # leaves room for the routing set to grow without churning this pin.
    assert {"true_false", "odd_one_out"} <= set(gen.calls[0]["mcq_patterns"])
