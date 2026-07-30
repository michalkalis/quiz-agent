"""Wiring fixes from the 2026-07-30 generation deep review (A2-A6, B, C).

Each test encodes the WHY of one fix so it cannot silently regress:

- A2: a fact-first template missing an injection placeholder must fail the
  generator at construction (entertainment shipped for weeks with the craft
  guards silently disabled).
- A4: the structured MCQ path must carry ONE output contract (the tool-schema
  note), never the prose-JSON block alongside a bound schema — and the
  model's ``why_interesting`` must survive into provenance.
- A6: a critique judge that fails twice returns None — never a fabricated
  neutral score.
- C: best-of-N final ordering comes from pairwise wins, not absolute scores
  (judges rank pairs far better than they place absolute scores).
- B: gold examples are founder-rated 8+ only; the prompt-cache breakpoint
  splits static prefix from dynamic tail only where the provider honours it.
"""

from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from quiz_shared.models.question import Question

from app.generation.advanced_generator import (
    AdvancedQuestionGenerator,
    CACHE_BREAKPOINT_MARKER,
    MCQBatchOutput,
    MCQQuestionItem,
)
from app.generation.examples import load_gold_standard
from app.generation.prompt_builder import STRUCTURED_MCQ_FORMAT_NOTE


@pytest.fixture(autouse=True)
def _stub_keys(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("OPENAI_API_KEY", "test-key-not-used")
    monkeypatch.setenv("OPENROUTER_API_KEY", "test-key-not-used")


_SOURCE_FACTS = [
    {
        "text": "A teaspoon of neutron star material weighs about a billion tonnes.",
        "source_url": "https://example.org/neutron-star",
        "source_name": "Example",
        "topic": "Space",
        "surprise_rating": 9.0,
    }
]


def _make_generator(**kwargs) -> AdvancedQuestionGenerator:
    return AdvancedQuestionGenerator(
        generation_model=kwargs.pop("generation_model", "gpt-4o"),
        critique_model="gpt-4o-mini",
        **kwargs,
    )


# --- A2: load-time placeholder assertion --------------------------------------


def test_tampered_fact_first_template_fails_at_construction(tmp_path, monkeypatch):
    """A template missing {craft_guards_section} must raise at load — the
    silent-no-op failure mode is exactly what let entertainment ship without
    guards."""
    import shutil
    import app.generation.advanced_generator as adv_mod
    from pathlib import Path

    prompts_dir = Path(adv_mod.__file__).resolve().parents[2] / "prompts"
    shutil.copytree(prompts_dir, tmp_path / "prompts")
    broken_path = tmp_path / "prompts" / "question_generation_v3_fact_first.md"
    broken = broken_path.read_text(encoding="utf-8").replace(
        "{craft_guards_section}", ""
    )
    broken_path.write_text(broken, encoding="utf-8")
    # Point the generator's prompts dir at the broken copy by monkeypatching
    # os.path.join resolution root — simplest faithful hook: chdir-independent,
    # so patch os.path.dirname to redirect the module's template root.
    real_dirname = adv_mod.os.path.dirname

    def _fake_dirname(path):
        if path == adv_mod.__file__:
            return str(tmp_path / "app" / "generation")
        return real_dirname(path)

    (tmp_path / "app" / "generation").mkdir(parents=True)
    monkeypatch.setattr(adv_mod.os.path, "dirname", _fake_dirname)

    with pytest.raises(ValueError, match="craft_guards_section"):
        AdvancedQuestionGenerator(
            generation_model="gpt-4o", critique_model="gpt-4o-mini"
        )


# --- A4: one output contract on the structured MCQ path -----------------------


def test_structured_mcq_prompt_carries_tool_note_not_prose_json():
    gen = _make_generator()
    prompt, _, _, use_fact_first = gen._build_batch_prompt(
        count=3,
        difficulty="medium",
        topics=None,
        categories=None,
        question_type="text_multichoice",
        excluded_topics=None,
        avoid_questions=None,
        user_bad_examples=None,
        source_facts=_SOURCE_FACTS,
        mcq_patterns={"true_false"},
        mcq_emphasis=True,
        response_format_section=STRUCTURED_MCQ_FORMAT_NOTE,
    )
    assert use_fact_first
    assert "bound tool schema" in prompt
    # The prose contract's scaffolding must NOT ride along.
    assert '"questions": [' not in prompt
    assert "self_critique" not in prompt


@pytest.mark.asyncio
async def test_structured_mcq_why_interesting_survives_to_provenance():
    gen = _make_generator()
    item = MCQQuestionItem(
        question="Is a day on Venus longer than its year?",
        possible_answers={"a": "True", "b": "False"},
        correct_answer="a",
        explanation="Venus rotates slower than it orbits.",
        topic="Space",
        pattern_used="true_false",
        why_interesting="Players assume a day is always shorter than a year.",
    )
    structured_stub = SimpleNamespace(
        ainvoke=AsyncMock(return_value=MCQBatchOutput(questions=[item]))
    )
    gen.generation_llm = SimpleNamespace(
        with_structured_output=lambda *a, **k: structured_stub,
        temperature=0.8,
    )

    questions = await gen._generate_mcq_batch_structured(
        count=1,
        difficulty="medium",
        topics=None,
        categories=None,
        question_type="text_multichoice",
        excluded_topics=None,
        avoid_questions=None,
        user_bad_examples=None,
        source_facts=_SOURCE_FACTS,
        mcq_patterns={"true_false"},
    )

    assert len(questions) == 1
    extra = questions[0].generation_metadata.extra
    assert extra.get("why_interesting") == (
        "Players assume a day is always shorter than a year."
    )


# --- A6 + A3: critique fail-loud and options visibility -----------------------


def _question(**overrides) -> Question:
    base = dict(
        question="Which planet has a hexagon-shaped storm?",
        type="text_multichoice",
        possible_answers={"a": "Saturn", "b": "Mars"},
        correct_answer="a",
        explanation="Saturn's north pole hosts a hexagonal jet stream.",
        topic="Space",
        category="general",
        difficulty="medium",
    )
    base.update(overrides)
    return Question.from_dict(base)


@pytest.mark.asyncio
async def test_critique_renders_options_and_answer_text():
    gen = _make_generator()
    captured: list[str] = []

    async def _capture(messages):
        captured.append(messages[0].content)
        return SimpleNamespace(
            content=json.dumps({"overall_score": 7.0, "scores": {}})
        )

    gen.critique_llm = SimpleNamespace(ainvoke=_capture)

    critique = await gen._critique_question(_question())

    assert critique is not None and critique["overall_score"] == 7.0
    sent = captured[0]
    assert "a) Saturn" in sent  # options visible (A3)
    assert "**Correct Answer:** Saturn" in sent  # letter resolved to text


@pytest.mark.asyncio
async def test_critique_returns_none_after_retry_never_a_default_score():
    gen = _make_generator()
    bad = SimpleNamespace(content="not json, sorry")
    stub = SimpleNamespace(ainvoke=AsyncMock(return_value=bad))
    gen.critique_llm = stub

    critique = await gen._critique_question(_question())

    assert critique is None
    assert stub.ainvoke.await_count == 2  # exactly one retry


# --- C: pairwise refinement decides the final order ---------------------------


@pytest.mark.asyncio
async def test_pairwise_wins_override_absolute_scores():
    """The candidate every pairwise comparison prefers must win selection even
    when its absolute critique score is the lowest of the shortlist."""
    gen = _make_generator()

    async def _judge(messages):
        content = messages[0].content
        a_part = content.split("QUESTION B:", 1)[0]
        winner = "A" if "TARGET" in a_part else "B"
        return SimpleNamespace(content=json.dumps({"winner": winner}))

    gen.critique_llm = SimpleNamespace(ainvoke=_judge)

    candidates = [
        (_question(question="TARGET question with the real reveal?"), 5.0),
        (_question(question="Filler one?"), 9.0),
        (_question(question="Filler two?"), 8.5),
        (_question(question="Filler three?"), 8.0),
    ]

    selected = await gen._select_top_pairwise(candidates, count=2)

    assert len(selected) == 2
    assert any("TARGET" in q.question for q in selected)


@pytest.mark.asyncio
async def test_pairwise_unparseable_verdicts_fall_back_to_absolute_order():
    gen = _make_generator()
    gen.critique_llm = SimpleNamespace(
        ainvoke=AsyncMock(return_value=SimpleNamespace(content="garbage"))
    )
    candidates = [
        (_question(question=f"Q{i}?"), float(10 - i)) for i in range(4)
    ]

    selected = await gen._select_top_pairwise(candidates, count=2)

    # All pairs skipped → absolute order decides; nothing crashes, count holds.
    assert [q.question for q in selected] == ["Q0?", "Q1?"]


# --- B: gold rating filter + cache breakpoint ---------------------------------


def test_gold_standard_filters_below_founder_rating(tmp_path, monkeypatch):
    import app.generation.examples as examples_mod

    data = [
        {
            "question": "GOLD-NINE question?",
            "answer": "Yes",
            "why_excellent": "great",
            "human_rating": 9,
            "pattern": "Surprising Connection",
        },
        {
            "question": "MID-FIVE question?",
            "answer": "No",
            "why_excellent": "meh",
            "human_rating": 5,
            "pattern": "Recall",
        },
    ]
    (tmp_path / "gold_standard.json").write_text(json.dumps(data), encoding="utf-8")
    monkeypatch.setattr(
        examples_mod, "example_corpus_path", lambda filename: tmp_path / filename
    )

    rendered = load_gold_standard()

    assert "GOLD-NINE" in rendered
    assert "MID-FIVE" not in rendered  # rated 5 must never pose as gold


def test_cache_breakpoint_splits_only_for_anthropic_over_openrouter(monkeypatch):
    gen = _make_generator(generation_model="claude-fable-5")
    prompt = f"STATIC{CACHE_BREAKPOINT_MARKER}DYNAMIC"

    monkeypatch.setenv("LLM_GATEWAY", "openrouter")
    content = gen._prompt_message_content(prompt)
    assert isinstance(content, list)
    assert content[0]["cache_control"] == {"type": "ephemeral"}
    assert content[0]["text"] == "STATIC"
    assert content[1]["text"] == "DYNAMIC"

    monkeypatch.setenv("LLM_GATEWAY", "direct")
    assert gen._prompt_message_content(prompt) == "STATICDYNAMIC"
