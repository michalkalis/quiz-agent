"""Unit tests for AdvancedQuestionGenerator (issue #42 task 42.9b).

Why these scenarios:

- `test_generate_batch_passes_mcq_through_when_pattern_in_set` pins the
  prompt-side MCQ wiring: when the LLM's stubbed response declares
  `reasoning.pattern_used = "true_false"` and emits a two-key
  `possible_answers`, `_generate_batch` must keep the options on the
  returned Question and lift `pattern_used` into the typed
  `generation_metadata.reasoning_pattern` slot so `GenerationStage`
  (42.9a) can route the question to `text_multichoice`.
- `test_generate_batch_text_when_pattern_not_in_set` pins the non-MCQ
  baseline: an `open_question` pattern with `possible_answers: null`
  must round-trip as a free-form question with no options. This is the
  fail-safe — non-MCQ patterns should never accidentally get tagged.
- `test_generate_batch_passes_mcq_patterns_into_prompt` is the contract
  test for the routing seam between `GenerationStage` and the prompt.
  If `mcq_patterns` ever stops reaching the prompt builder, MCQ rules
  silently vanish from the prompt and the LLM stops emitting options —
  this test breaks loudly when that wire is cut.
- `test_format_mcq_patterns_section_empty_when_no_patterns` locks the
  back-compat shape: scripts and ad-hoc callers that don't pass
  `mcq_patterns` must still render a usable prompt (empty section, no
  KeyError from the template's `.format()`).
"""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from app.generation.advanced_generator import AdvancedQuestionGenerator


@pytest.fixture(autouse=True)
def _stub_openai_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """Avoid ChatOpenAI's env-var assertion at construction time."""
    monkeypatch.setenv("OPENAI_API_KEY", "test-key-not-used")


def _make_generator_with_fake_llm(fake_ainvoke: AsyncMock) -> AdvancedQuestionGenerator:
    """Build a generator whose `generation_llm` is a stub.

    `ChatOpenAI` is a Pydantic v2 model and rejects attribute patching, so
    instead of `patch.object(..., "ainvoke")` we swap the whole LLM out for
    a `SimpleNamespace`. `_generate_batch` only reads `.ainvoke` and
    `.temperature` on this object, so a thin stub is sufficient.
    """
    gen = AdvancedQuestionGenerator(
        generation_model="gpt-4o",
        critique_model="gpt-4o-mini",
        prompt_version="v2_cot",
    )
    gen.generation_llm = SimpleNamespace(ainvoke=fake_ainvoke, temperature=0.8)
    return gen


def _llm_response(content: str) -> SimpleNamespace:
    """Match the langchain `AIMessage` shape `_generate_batch` reads."""
    return SimpleNamespace(content=content)


_MCQ_RESPONSE = """{
  "questions": [
    {
      "id": "q_test_mcq",
      "reasoning": {
        "pattern_used": "true_false",
        "why_interesting": "stub",
        "universal_appeal": "stub",
        "boring_check": "stub"
      },
      "question": "Is the sky blue on a clear day?",
      "type": "text_multichoice",
      "correct_answer": "a",
      "possible_answers": {"a": "True", "b": "False"},
      "alternative_answers": [],
      "topic": "Science",
      "category": "general",
      "difficulty": "easy",
      "tags": [],
      "language_dependent": false,
      "age_appropriate": "all"
    }
  ]
}"""


_TEXT_RESPONSE = """{
  "questions": [
    {
      "id": "q_test_text",
      "reasoning": {
        "pattern_used": "open_question",
        "why_interesting": "stub",
        "universal_appeal": "stub",
        "boring_check": "stub"
      },
      "question": "What is the capital of France?",
      "type": "text",
      "correct_answer": "Paris",
      "possible_answers": null,
      "alternative_answers": [],
      "topic": "Geography",
      "category": "general",
      "difficulty": "easy",
      "tags": [],
      "language_dependent": false,
      "age_appropriate": "all"
    }
  ]
}"""


@pytest.mark.asyncio
async def test_generate_batch_passes_mcq_through_when_pattern_in_set() -> None:
    fake_ainvoke = AsyncMock(return_value=_llm_response(_MCQ_RESPONSE))
    gen = _make_generator_with_fake_llm(fake_ainvoke)
    questions = await gen._generate_batch(
        count=1,
        difficulty="easy",
        topics=None,
        categories=["general"],
        question_type="text",
        excluded_topics=None,
        avoid_questions=None,
        user_bad_examples=None,
        mcq_patterns={"true_false", "odd_one_out"},
    )

    assert len(questions) == 1
    q = questions[0]
    assert q.possible_answers is not None
    assert len(q.possible_answers) == 2
    assert q.possible_answers == {"a": "True", "b": "False"}
    assert q.correct_answer == "a"
    assert q.generation_metadata is not None
    assert q.generation_metadata.reasoning_pattern == "true_false"


@pytest.mark.asyncio
async def test_generate_batch_text_when_pattern_not_in_set() -> None:
    fake_ainvoke = AsyncMock(return_value=_llm_response(_TEXT_RESPONSE))
    gen = _make_generator_with_fake_llm(fake_ainvoke)
    questions = await gen._generate_batch(
        count=1,
        difficulty="easy",
        topics=None,
        categories=["general"],
        question_type="text",
        excluded_topics=None,
        avoid_questions=None,
        user_bad_examples=None,
        mcq_patterns={"true_false", "odd_one_out"},
    )

    assert len(questions) == 1
    q = questions[0]
    assert q.possible_answers is None
    assert q.correct_answer == "Paris"
    assert q.generation_metadata is not None
    assert q.generation_metadata.reasoning_pattern == "open_question"


@pytest.mark.asyncio
async def test_generate_batch_passes_mcq_patterns_into_prompt() -> None:
    """The MCQ section must reach the prompt builder via `mcq_patterns_section`.

    We assert against the prompt string `ainvoke` was called with — that's the
    seam between `GenerationStage`'s configuration of MCQ patterns and the LLM
    actually seeing the rules. If this regresses, the LLM stops emitting
    options for MCQ patterns and 42.9a silently drops every routed question.
    """
    fake_ainvoke = AsyncMock(return_value=_llm_response(_TEXT_RESPONSE))
    gen = _make_generator_with_fake_llm(fake_ainvoke)
    await gen._generate_batch(
        count=1,
        difficulty="easy",
        topics=None,
        categories=["general"],
        question_type="text",
        excluded_topics=None,
        avoid_questions=None,
        user_bad_examples=None,
        mcq_patterns={"true_false", "year_guess"},
    )

    sent_messages = fake_ainvoke.await_args.args[0]
    prompt_text = sent_messages[0].content
    assert "Multiple-Choice Activation" in prompt_text
    assert "`true_false`" in prompt_text
    assert "`year_guess`" in prompt_text


@pytest.mark.asyncio
async def test_generate_batch_emphasis_puts_quota_in_prompt() -> None:
    """42.20 blocker root cause D: the quota must reach the generation LLM.

    `mcq_emphasis=True` (an `--mcq-bias` order) must surface the hard quota
    in the prompt `ainvoke` receives — the order prompt itself never does.
    """
    fake_ainvoke = AsyncMock(return_value=_llm_response(_TEXT_RESPONSE))
    gen = _make_generator_with_fake_llm(fake_ainvoke)
    await gen._generate_batch(
        count=1,
        difficulty="easy",
        topics=None,
        categories=["general"],
        question_type="text",
        excluded_topics=None,
        avoid_questions=None,
        user_bad_examples=None,
        mcq_patterns={"true_false", "year_guess"},
        mcq_emphasis=True,
    )

    prompt_text = fake_ainvoke.await_args.args[0][0].content
    assert "MULTIPLE-CHOICE EMPHASIS" in prompt_text
    assert "at least 7 of every 10 questions" in prompt_text


def test_format_mcq_patterns_section_empty_when_no_patterns() -> None:
    assert AdvancedQuestionGenerator._format_mcq_patterns_section(None) == ""
    assert AdvancedQuestionGenerator._format_mcq_patterns_section(set()) == ""


def test_format_mcq_patterns_section_lists_each_pattern() -> None:
    section = AdvancedQuestionGenerator._format_mcq_patterns_section(
        {"true_false", "odd_one_out"}
    )
    assert "## Multiple-Choice Activation" in section
    assert "`true_false`" in section
    assert "`odd_one_out`" in section
    # Distractor-quality rule is non-negotiable (issue plan 42.10 follow-up).
    assert "Distractor quality rule" in section
    # 42.20 BLOCKER root cause D: the old self-gated carve-out ("if the
    # order prompt declares MULTIPLE-CHOICE EMPHASIS") was dead code — the
    # generation LLM never sees the order prompt. Default (unbiased) runs
    # must NOT carry the quota or the diversity-cap exemption.
    assert "MULTIPLE-CHOICE EMPHASIS" not in section
    assert "EXEMPT" not in section


def test_format_mcq_patterns_section_emphasis_injects_hard_quota() -> None:
    # 42.20 BLOCKER root causes B+D: `--mcq-bias` orders plumb
    # `mcq_emphasis=True` through OrderContext → GenerationStage →
    # `generate_questions`, and the hard quota + diversity-cap exemption
    # must land directly in the section the generation LLM actually reads.
    section = AdvancedQuestionGenerator._format_mcq_patterns_section(
        {"true_false", "odd_one_out"}, mcq_emphasis=True
    )
    assert "MULTIPLE-CHOICE EMPHASIS" in section
    assert "at least 7 of every 10 questions" in section
    assert "EXEMPT" in section
    assert "PATTERN DIVERSITY RULE" in section


def test_format_mcq_patterns_section_bridges_library_patterns() -> None:
    # 42.20 BLOCKER root cause E: the generation LLM selects from the numbered
    # Pattern Library, but `true_false`/`year_guess` are not in it and
    # `odd_one_out`/`comparison_bet` use different labels there — so the LLM
    # never picked an MCQ-routable pattern (0/10 live). The activation block
    # must bridge library titles → snake_case keys and flag the two unnumbered
    # keys as directly selectable, or the prompt fix silently regresses.
    section = AdvancedQuestionGenerator._format_mcq_patterns_section(
        {"true_false", "odd_one_out", "comparison_bet_older_larger", "year_guess"}
    )
    assert "Pattern Library" in section
    # the library-mapped MCQ patterns name their numbered origin
    assert "#9" in section and "#12" in section
    # the two unnumbered keys are flagged as pickable in their own right
    assert "true_false" in section and "year_guess" in section
    assert "selectable choices" in section


def test_format_mcq_patterns_section_includes_order_of_magnitude_recipe() -> None:
    # Issue #72 P1.4: the unlocked bucketed-estimate pattern must carry its own
    # emission recipe (magnitude buckets) AND be flagged as directly selectable
    # in the bridging prose — without both, the generation LLM never picks it
    # (root cause E) and the PATTERNS_TO_MCQ entry is a dead unlock.
    section = AdvancedQuestionGenerator._format_mcq_patterns_section(
        {"order_of_magnitude"}
    )
    assert "`order_of_magnitude`" in section
    assert "bucket" in section.lower()
    assert "selectable choices" in section


def test_format_mcq_patterns_section_comparison_bet_recipe_is_broadened() -> None:
    # Issue #72 P1.4: the comparison-bet recipe is broadened beyond the stale
    # older/larger/heavier trio (via the recipe string, NOT a key rename) so
    # the LLM can bet on more surprising dimensions. The canonical key is
    # unchanged — a rename would break the 42.20 alias contract.
    section = AdvancedQuestionGenerator._format_mcq_patterns_section(
        {"comparison_bet_older_larger"}
    )
    assert "`comparison_bet_older_larger`" in section
    # at least one newly added dimension is present
    assert "faster" in section


# --- Issue #46 task 46.B4b — open/logical branch generation ---------------
#
# Why these scenarios: B4b wires `question_generation_open.md` (B3) into the
# generator so open-shape questions are *actually* produced with the two-field
# `headline_answer` + `explanation` contract — not just post-tagged (B4a). The
# tests pin (1) that the open slice is generated through the open prompt (the
# prompt text is the only seam proving the right template was used), (2) that
# `headline_answer` survives the parse onto the returned Question, and (3) that
# a pure lateral puzzle is tagged `pipeline="logical_puzzle"` at generation
# time so F8's source_url relaxation (B4a/D4) applies, while an open-mechanism
# question stays web-verifiable (no special pipeline).

_OPEN_PUZZLE_RESPONSE = """{
  "questions": [
    {
      "id": "q_open_puzzle",
      "reasoning": {"pattern_used": "lateral_thinking", "why_interesting": "x",
        "universal_appeal": "x", "boring_check": "x"},
      "question": "A man pushes his car to a hotel and loses his fortune. Why?",
      "type": "text",
      "headline_answer": "He is playing Monopoly",
      "correct_answer": "He is playing Monopoly and landed on a hotel-owned property",
      "explanation": "The car is a Monopoly token; he landed on a hotel-owned property.",
      "alternative_answers": ["It's a board game"],
      "possible_answers": null,
      "topic": "Puzzles",
      "category": "general",
      "difficulty": "medium",
      "tags": [],
      "language_dependent": false,
      "age_appropriate": "all"
    }
  ]
}"""

_OPEN_MECHANISM_RESPONSE = """{
  "questions": [
    {
      "id": "q_open_mech",
      "reasoning": {"pattern_used": "open_question", "why_interesting": "x",
        "universal_appeal": "x", "boring_check": "x"},
      "question": "Why are Ferraris traditionally red?",
      "type": "text",
      "headline_answer": "Italy's national racing colour",
      "correct_answer": "Italy's national racing colour (rosso corsa)",
      "explanation": "Early-1900s Grand Prix rules assigned each nation a colour; red went to Italy.",
      "alternative_answers": ["rosso corsa"],
      "possible_answers": null,
      "topic": "Cars",
      "category": "general",
      "difficulty": "medium",
      "tags": [],
      "language_dependent": false,
      "age_appropriate": "all"
    }
  ]
}"""


@pytest.mark.asyncio
async def test_open_count_generates_through_open_prompt_with_headline_answer() -> None:
    fake_ainvoke = AsyncMock(return_value=_llm_response(_OPEN_PUZZLE_RESPONSE))
    gen = _make_generator_with_fake_llm(fake_ainvoke)

    questions = await gen.generate_questions(
        count=1,
        open_count=1,
        difficulty="medium",
        categories=["general"],
    )

    # The open slice is the whole batch (count - open_count == 0), so best-of-N
    # never runs and the critique LLM is untouched.
    assert len(questions) == 1
    q = questions[0]
    assert q.headline_answer == "He is playing Monopoly"
    # Pure lateral puzzle → tagged so F8 lets it persist without a source_url.
    assert q.generation_metadata is not None
    assert q.generation_metadata.pipeline == "logical_puzzle"
    assert q.generation_metadata.prompt_version == "open"

    # Proof the open template (not v2/v3 fact-first) produced this question.
    prompt_text = fake_ainvoke.await_args.args[0][0].content
    assert "Open / Logical Branch" in prompt_text


@pytest.mark.asyncio
async def test_open_mechanism_keeps_factual_pipeline() -> None:
    fake_ainvoke = AsyncMock(return_value=_llm_response(_OPEN_MECHANISM_RESPONSE))
    gen = _make_generator_with_fake_llm(fake_ainvoke)

    questions = await gen.generate_questions(
        count=1, open_count=1, difficulty="medium", categories=["general"]
    )

    q = questions[0]
    assert q.headline_answer == "Italy's national racing colour"
    # Open-mechanism answers are web-verifiable → no logical_puzzle tag, so F8
    # still requires a source_url for them (R3).
    assert q.generation_metadata.pipeline != "logical_puzzle"


def test_extract_pattern_used_returns_none_for_missing_provenance() -> None:
    assert AdvancedQuestionGenerator._extract_pattern_used(None) is None


def test_extract_pattern_used_pulls_from_extra_reasoning() -> None:
    from quiz_shared.models.question import GenerationProvenance

    prov = GenerationProvenance(extra={"reasoning": {"pattern_used": "year_guess"}})
    assert AdvancedQuestionGenerator._extract_pattern_used(prov) == "year_guess"


def test_extract_pattern_used_returns_none_when_reasoning_not_dict() -> None:
    from quiz_shared.models.question import GenerationProvenance

    # Defensive: legacy rows or malformed LLM output may put a string here.
    prov = GenerationProvenance(extra={"reasoning": "not a dict"})
    assert AdvancedQuestionGenerator._extract_pattern_used(prov) is None


@pytest.mark.asyncio
async def test_mcq_emphasis_fans_out_one_sub_batch_per_pattern() -> None:
    """Issue #42 task 42.20 (Risk #7 escalation).

    An MCQ-emphasis order must NOT route through the best-of-N path, which
    asked the LLM for `count * n_multiplier` (~57) questions in one call and
    let the model satisfy the quota with whichever single MCQ pattern was
    easiest (or none). Instead `generate_questions` must split `count` into
    one small sub-batch per pattern in `mcq_patterns`, each pinned to that
    single pattern. This is what forces per-pattern MCQ coverage and keeps
    per-call counts small enough that the LLM fills them. We stub
    `_generate_mcq_batch_structured` (the per-sub-batch helper since #42
    task 42.25) so the assertion is purely about the fan-out shape, not
    live generation.
    """
    from app.generation.pattern_routing import PATTERNS_TO_MCQ

    patterns = set(PATTERNS_TO_MCQ)

    # Each sub-batch returns `count` sentinel questions so we can prove the
    # per-pattern counts sum back to the requested total.
    async def _fake_batch(*, count: int, **_kwargs):
        return ["q"] * count

    gen = _make_generator_with_fake_llm(AsyncMock())
    gen._generate_mcq_batch_structured = AsyncMock(side_effect=_fake_batch)

    questions = await gen.generate_questions(
        count=12,
        difficulty="medium",
        topics=["science"],
        mcq_patterns=patterns,
        mcq_emphasis=True,
        open_count=0,
    )

    calls = gen._generate_mcq_batch_structured.await_args_list
    # One call per MCQ pattern — no single large best-of-N blow-up.
    assert len(calls) == len(patterns)
    seen_patterns = set()
    total = 0
    for call in calls:
        kwargs = call.kwargs
        # Each sub-batch is pinned to exactly one pattern.
        assert len(kwargs["mcq_patterns"]) == 1
        # Per-call counts stay small — never the count*n_multiplier (~57) blow-up.
        assert kwargs["count"] <= 5
        seen_patterns |= kwargs["mcq_patterns"]
        total += kwargs["count"]
    # Every MCQ pattern got coverage and the split sums to the requested count.
    assert seen_patterns == patterns
    assert total == 12
    assert len(questions) == 12


@pytest.mark.asyncio
async def test_mcq_sub_batch_failure_does_not_sink_the_rest() -> None:
    """Issue #72 P1.3 (= #42 task 42.31) — MCQ sub-batch crash isolation.

    The per-pattern sub-batches fan out through ``asyncio.gather``. Before
    this fix the bare gather propagated the first failing coroutine and
    cancelled the others, so one bad pattern (an LLM timeout or malformed
    structured-output parse) sank the entire MCQ order. The sub-batches are
    now isolated (per-batch try/except + ``return_exceptions=True``), so a
    failure drops only its own pattern's questions while every sibling
    sub-batch is still attempted and its questions survive. This matters
    because a single flaky pattern silently zeroing a whole order is exactly
    the kind of yield collapse #42 fought to remove.
    """
    from app.generation.pattern_routing import PATTERNS_TO_MCQ

    patterns = sorted(PATTERNS_TO_MCQ)
    # The isolation property is only meaningful with a surviving sibling.
    assert len(patterns) >= 2
    doomed = patterns[0]

    async def _fake_batch(*, count: int, mcq_patterns, **_kwargs):
        if doomed in mcq_patterns:
            raise RuntimeError("structured output parse failed")
        return ["q"] * count

    gen = _make_generator_with_fake_llm(AsyncMock())
    gen._generate_mcq_batch_structured = AsyncMock(side_effect=_fake_batch)

    # Must not raise even though one sub-batch blows up.
    questions = await gen.generate_questions(
        count=12,
        difficulty="medium",
        topics=["science"],
        mcq_patterns=set(patterns),
        mcq_emphasis=True,
        open_count=0,
    )

    # Every pattern was still attempted — the failure did NOT cancel siblings.
    assert gen._generate_mcq_batch_structured.await_count == len(patterns)
    # Only the doomed pattern's share is lost; all other questions survive.
    base, extra = divmod(12, len(patterns))
    doomed_share = base + (1 if extra else 0)  # sorted()[0] absorbs the first remainder
    assert len(questions) == 12 - doomed_share
    assert len(questions) > 0


@pytest.mark.asyncio
async def test_mcq_sub_batch_uses_structured_output() -> None:
    """Issue #42 task 42.25 — the contract test for the un-park gate.

    The live MCQ yield collapsed to 2/13 because the v3 prompt's Response
    Format example shows `possible_answers: null`; the model copied the
    template default and emitted free-form `text`, which 42.9a then dropped
    (`dropped_mcq_missing_options: 0` — it never even attempted MCQ).
    Prompt instructions cannot beat a template default — so each MCQ
    sub-batch now binds `MCQBatchOutput` via
    `generation_llm.with_structured_output(...)`, making
    `type="text_multichoice"` + populated `possible_answers` a parse-time
    guarantee. This test pins that guarantee: a stubbed structured call
    must yield only `text_multichoice` questions with options. If someone
    reverts the sub-batch to the free-text `_generate_batch` path, the
    options vanish and this breaks loudly.
    """
    from app.generation.advanced_generator import MCQBatchOutput, MCQQuestionItem

    batch_out = MCQBatchOutput(
        questions=[
            MCQQuestionItem(
                question="True or false: the Great Wall is visible from space.",
                possible_answers={"a": "True", "b": "False"},
                correct_answer="b",
                pattern_used="true_false",
                explanation="It is not visible to the naked eye from orbit.",
            ),
            MCQQuestionItem(
                question="Which is the odd one out?",
                possible_answers={
                    "a": "Mercury",
                    "b": "Venus",
                    "c": "Mars",
                    "d": "Pluto",
                },
                correct_answer="d",
                pattern_used="true_false",
                explanation="Pluto is a dwarf planet.",
            ),
        ]
    )

    structured_chain = SimpleNamespace(ainvoke=AsyncMock(return_value=batch_out))
    captured = {}

    def _with_structured_output(schema, **kwargs):
        captured["schema"] = schema
        captured["method"] = kwargs.get("method")
        return structured_chain

    gen = _make_generator_with_fake_llm(AsyncMock())
    gen.generation_llm = SimpleNamespace(
        with_structured_output=_with_structured_output,
        temperature=0.8,
    )

    questions = await gen._generate_mcq_batch_structured(
        count=2,
        difficulty="medium",
        topics=["science"],
        categories=["general"],
        question_type="text",
        excluded_topics=None,
        avoid_questions=None,
        user_bad_examples=None,
        source_facts=None,
        mcq_patterns={"true_false"},
    )

    assert len(questions) == 2
    # The whole point of 42.25 — every question is a real MCQ, not free text.
    assert all(q.type == "text_multichoice" for q in questions)
    assert all(q.possible_answers for q in questions)
    assert questions[0].correct_answer == "b"
    # The pattern is lifted into typed provenance for downstream routing/analytics.
    assert questions[0].generation_metadata.reasoning_pattern == "true_false"
    # Gateway-safe binding: function_calling, not the json_schema default.
    assert captured["schema"] is MCQBatchOutput
    assert captured["method"] == "function_calling"


@pytest.mark.asyncio
async def test_mcq_sub_batches_partition_source_facts_disjointly() -> None:
    """Issue #42 task 42.28 — each MCQ sub-batch gets a distinct fact slice.

    Before 42.28 every per-pattern sub-batch was handed the *same*
    `source_facts`, so the patterns mined the same handful of facts and the
    pack filled with near-duplicates (e.g. four variants of one Bob Dylan
    fact). Each sub-batch must now receive a disjoint contiguous slice so the
    patterns draw on different material. We stub the structured helper and
    inspect the `source_facts` each call received: the slices must be pairwise
    disjoint and together cover every fact exactly once. If someone reverts to
    passing the shared list, the coverage assertion (facts counted N×) breaks.
    """
    facts = [f"fact-{i}" for i in range(9)]
    patterns = {"alpha", "bravo", "charlie"}

    async def _fake_batch(*, source_facts, **_kwargs):
        return list(source_facts or [])

    gen = _make_generator_with_fake_llm(AsyncMock())
    gen._generate_mcq_batch_structured = AsyncMock(side_effect=_fake_batch)

    await gen._generate_mcq_sub_batches(
        count=9,
        difficulty="medium",
        topics=["history"],
        categories=["general"],
        excluded_topics=None,
        avoid_questions=None,
        user_bad_examples=None,
        source_facts=facts,
        mcq_patterns=patterns,
    )

    slices = [
        call.kwargs["source_facts"]
        for call in gen._generate_mcq_batch_structured.await_args_list
    ]
    # One slice per pattern (9 facts / 3 patterns = 3 each, all non-empty).
    assert len(slices) == len(patterns)
    assert all(s for s in slices)
    flattened = [f for s in slices for f in s]
    # Disjoint: no fact appears in two slices.
    assert len(flattened) == len(set(flattened))
    # Covering: every source fact is used exactly once across the sub-batches.
    assert set(flattened) == set(facts)
    assert len(flattened) == len(facts)


def _fake_mcq_questions(n: int, pattern: str) -> list:
    """Real ``Question`` objects in the shape the structured MCQ sub-batch
    returns — each already carries provenance (set by ``_finalize_questions``),
    so the P4.2 telemetry pass has somewhere to stamp the critique score."""
    from quiz_shared.models.question import GenerationProvenance, Question

    out = []
    for i in range(n):
        q = Question(
            id=f"q_{pattern}_{i}",
            question=f"Is fact {i} about {pattern} true?",
            type="text_multichoice",
            possible_answers={"a": "True", "b": "False"},
            correct_answer="a",
            topic="History",
            category="general",
            difficulty="medium",
        )
        q.generation_metadata = GenerationProvenance(
            model="gpt-4o",
            reasoning_pattern=pattern,
            extra={"stage": "initial_generation"},
        )
        out.append(q)
    return out


@pytest.mark.asyncio
async def test_mcq_critique_telemetry_annotates_each_question_when_flag_on(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Issue #72 P4.2 (RC-7) — restore self_critique telemetry on the MCQ path.

    The text best-of-N path records a ``critique_score`` per question, but the
    per-pattern MCQ sub-batch path recorded none — so MCQ "fun" was measured in
    0 places. With ``MCQ_CRITIQUE_TELEMETRY`` on, the critique judge must run
    once per kept MCQ question and stamp its score into provenance, WITHOUT
    dropping anything (re-introducing the ~57-question over-generation is the
    very failure mode this sub-batch path replaced). Removing the telemetry
    wiring breaks the await-count / metadata assertions loudly.
    """
    monkeypatch.setenv("MCQ_CRITIQUE_TELEMETRY", "1")
    patterns = {"alpha", "bravo"}

    async def _fake_batch(*, count, mcq_patterns, **_kwargs):
        return _fake_mcq_questions(count, next(iter(mcq_patterns)))

    gen = _make_generator_with_fake_llm(AsyncMock())
    gen._generate_mcq_batch_structured = AsyncMock(side_effect=_fake_batch)
    gen._critique_question = AsyncMock(
        return_value={"overall_score": 8.5, "verdict": "excellent"}
    )

    questions = await gen._generate_mcq_sub_batches(
        count=4,
        difficulty="medium",
        topics=["history"],
        categories=["general"],
        excluded_topics=None,
        avoid_questions=None,
        user_bad_examples=None,
        source_facts=None,
        mcq_patterns=patterns,
    )

    # Telemetry, not selection: every generated MCQ question survives.
    assert len(questions) == 4
    # The judge ran exactly once per kept question — never the ~57 blow-up.
    assert gen._critique_question.await_count == 4
    for q in questions:
        assert q.generation_metadata is not None
        assert q.generation_metadata.critique_score == 8.5
        assert q.generation_metadata.critique_model == gen.critique_model
        # The full critique dict is merged into provenance.extra for audit,
        # without clobbering the existing generation stage marker.
        assert q.generation_metadata.extra["verdict"] == "excellent"
        assert q.generation_metadata.extra["stage"] == "initial_generation"


@pytest.mark.asyncio
async def test_mcq_critique_telemetry_dormant_when_flag_off(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """P4.2 dormancy — with ``MCQ_CRITIQUE_TELEMETRY`` unset (default), the MCQ
    sub-batch path makes ZERO critique calls and the questions pass through
    unannotated, so the shipped per-pattern architecture (and its cost) is
    byte-identical to today."""
    monkeypatch.delenv("MCQ_CRITIQUE_TELEMETRY", raising=False)
    patterns = {"alpha", "bravo"}

    async def _fake_batch(*, count, mcq_patterns, **_kwargs):
        return _fake_mcq_questions(count, next(iter(mcq_patterns)))

    gen = _make_generator_with_fake_llm(AsyncMock())
    gen._generate_mcq_batch_structured = AsyncMock(side_effect=_fake_batch)
    gen._critique_question = AsyncMock()

    questions = await gen._generate_mcq_sub_batches(
        count=4,
        difficulty="medium",
        topics=["history"],
        categories=["general"],
        excluded_topics=None,
        avoid_questions=None,
        user_bad_examples=None,
        source_facts=None,
        mcq_patterns=patterns,
    )

    assert len(questions) == 4
    gen._critique_question.assert_not_awaited()
    # No critique telemetry stamped when dormant.
    assert all(q.generation_metadata.critique_score is None for q in questions)


def test_partition_facts_handles_none_and_short_inputs() -> None:
    """#42 task 42.28 — the partition helper degrades gracefully.

    With no facts (or fewer facts than patterns) the spare sub-batch slots
    must get `None` so those sub-batches fall back to the fact-free prompt
    (pre-42.28 behaviour) rather than raising or duplicating facts.
    """
    # No facts → every slot is None (fact-free prompt fallback).
    assert AdvancedQuestionGenerator._partition_facts(None, 3) == [None, None, None]
    assert AdvancedQuestionGenerator._partition_facts([], 3) == [None, None, None]
    # Fewer facts than patterns → first slots filled, rest None, still disjoint.
    assert AdvancedQuestionGenerator._partition_facts(["x", "y"], 3) == [["x"], ["y"], None]
