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
    single pattern with `mcq_emphasis=True`. This is what forces per-pattern
    MCQ coverage and keeps per-call counts small enough that the LLM fills
    them. We stub `_generate_batch` so the assertion is purely about the
    fan-out shape, not live generation.
    """
    from app.generation.pattern_routing import PATTERNS_TO_MCQ

    patterns = set(PATTERNS_TO_MCQ)

    # Each sub-batch returns `count` sentinel questions so we can prove the
    # per-pattern counts sum back to the requested total.
    async def _fake_batch(*, count: int, **_kwargs):
        return ["q"] * count

    gen = _make_generator_with_fake_llm(AsyncMock())
    gen._generate_batch = AsyncMock(side_effect=_fake_batch)

    questions = await gen.generate_questions(
        count=12,
        difficulty="medium",
        topics=["science"],
        mcq_patterns=patterns,
        mcq_emphasis=True,
        open_count=0,
    )

    calls = gen._generate_batch.await_args_list
    # One call per MCQ pattern — no single large best-of-N blow-up.
    assert len(calls) == len(patterns)
    seen_patterns = set()
    total = 0
    for call in calls:
        kwargs = call.kwargs
        # Each sub-batch is pinned to exactly one pattern, in emphasis mode.
        assert len(kwargs["mcq_patterns"]) == 1
        assert kwargs["mcq_emphasis"] is True
        # Per-call counts stay small — never the count*n_multiplier (~57) blow-up.
        assert kwargs["count"] <= 5
        seen_patterns |= kwargs["mcq_patterns"]
        total += kwargs["count"]
    # Every MCQ pattern got coverage and the split sums to the requested count.
    assert seen_patterns == patterns
    assert total == 12
    assert len(questions) == 12
