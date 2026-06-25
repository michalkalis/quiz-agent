"""Flag-gated prompt assertions for the v3 escape hatch (issue #72 P2.2).

Why this test exists
--------------------
RC-5 (issue #72, Diagnosis B): the live `v3_fact_first` prompt hard-binds every
question to a source fact with *no room for a surprising angle* — "rely ONLY on
the source facts, never your own knowledge". That is a direct cause of the
"prvoplánové" (first-degree-recall) output. Lever B's fix is an **escape hatch**:
allow a surprising angle/framing drawn from general knowledge **as long as the
core factual claim still traces to a source fact**, so the grounding that v3 was
built to guarantee is preserved.

Because this is the highest-risk prompt change in the issue, it ships **dormant
behind `V3_ESCAPE_HATCH`** and must be fully revertible. These assertions lock in
the contract the plan requires:

- flag OFF (default): the built v3 prompt is byte-identical to today — no escape
  hatch text leaks in, so production behaviour is unchanged.
- flag ON: the escape hatch appears, AND it keeps the grounding condition (the
  answer must still trace to a source) — the hatch must never become a licence to
  fabricate, which is the exact risk v3 exists to remove.

The assertions build the prompt through the real `_build_batch_prompt` path
(not a raw file read) so they exercise the flag wiring, not just the template.
"""

from __future__ import annotations

import pytest

from app.generation.advanced_generator import (
    AdvancedQuestionGenerator,
    _V3_ESCAPE_HATCH_SECTION,
)


@pytest.fixture(autouse=True)
def _stub_openai_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """Avoid ChatOpenAI's env-var assertion at construction time."""
    monkeypatch.setenv("OPENAI_API_KEY", "test-key-not-used")


_SOURCE_FACTS = [
    {
        "text": "A teaspoon of neutron star material weighs about a billion tonnes.",
        "source_url": "https://example.org/neutron-star",
        "source_name": "Example",
        "topic": "Space",
        "surprise_rating": 9.0,
    }
]


def _build_v3_prompt() -> str:
    """Render the live v3 prompt via the real generation path.

    `source_facts` is non-empty so `use_fact_first` is true and the v3 builder
    is selected — the same branch production takes since SourcingStage became
    mandatory (Diagnosis A). Returns the prompt string only.
    """
    gen = AdvancedQuestionGenerator(
        generation_model="gpt-4o",
        critique_model="gpt-4o-mini",
        prompt_version="v3_fact_first",
    )
    prompt, prompt_version, _use_open, use_fact_first = gen._build_batch_prompt(
        count=5,
        difficulty="medium",
        topics=None,
        categories=None,
        question_type="text",
        excluded_topics=None,
        avoid_questions=None,
        user_bad_examples=None,
        source_facts=_SOURCE_FACTS,
    )
    # Guard: if this ever stops selecting the v3 fact-first path the assertions
    # below would pass vacuously, so prove we are on it.
    assert use_fact_first is True
    assert prompt_version == "v3_fact_first"
    return prompt


def test_escape_hatch_absent_when_flag_off(monkeypatch: pytest.MonkeyPatch) -> None:
    """Default (dormant): no escape hatch text reaches the live v3 prompt, so
    production output is unchanged until the founder flips the flag at Phase 6."""
    monkeypatch.delenv("V3_ESCAPE_HATCH", raising=False)
    prompt = _build_v3_prompt()
    assert "Escape Hatch" not in prompt
    # Sanity: we really did render the fact-first prompt (so the absence above
    # is meaningful, not because the v3 template was skipped).
    assert "SOURCE FACTS" in prompt


def test_escape_hatch_present_when_flag_on(monkeypatch: pytest.MonkeyPatch) -> None:
    """Flag on: the surprising-angle escape hatch appears in the prompt."""
    monkeypatch.setenv("V3_ESCAPE_HATCH", "1")
    prompt = _build_v3_prompt()
    assert "Escape Hatch: A Surprising Angle" in prompt


def test_escape_hatch_keeps_factual_grounding(monkeypatch: pytest.MonkeyPatch) -> None:
    """The hatch must loosen only the *angle*, never the *answer*: the answer has
    to keep tracing to a source fact. Without this clause the hatch would
    reintroduce the hallucination risk v3 was built to remove (Do-NOT-retry list:
    'pure-imagination generation')."""
    monkeypatch.setenv("V3_ESCAPE_HATCH", "true")
    prompt = _build_v3_prompt()
    assert "still traces to one of the source facts above" in prompt
    assert "never for the *answer*" in prompt


def test_flag_off_prompt_is_byte_identical_minus_the_hatch() -> None:
    """Revertibility proof: the ONLY difference the flag makes is the escape hatch
    block. Removing that block from the on-prompt yields exactly the off-prompt —
    so flipping `V3_ESCAPE_HATCH` off is a true revert, nothing else shifts.

    Built straight through the v3 `PromptBuilder` (not `_build_batch_prompt`) with
    the two randomly-sampled sections pinned (`excellent_examples`,
    `bad_examples_section`), so the escape hatch is the sole variable — the
    flag-gated `_build_batch_prompt` wiring is already covered by the substring
    tests above."""
    gen = AdvancedQuestionGenerator(
        generation_model="gpt-4o",
        critique_model="gpt-4o-mini",
        prompt_version="v3_fact_first",
    )
    pinned = dict(
        count=5,
        difficulty="medium",
        topics=None,
        categories=None,
        question_type="text",
        excellent_examples="<<PINNED EXAMPLES>>",
        facts_section="<<PINNED FACTS>>",
        bad_examples_section="",
    )
    prompt_off = gen.v3_prompt_builder.build_prompt(escape_hatch_section="", **pinned)
    prompt_on = gen.v3_prompt_builder.build_prompt(
        escape_hatch_section=_V3_ESCAPE_HATCH_SECTION, **pinned
    )
    assert prompt_on != prompt_off
    assert prompt_on.replace(_V3_ESCAPE_HATCH_SECTION, "") == prompt_off
