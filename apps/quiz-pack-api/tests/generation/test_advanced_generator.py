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
