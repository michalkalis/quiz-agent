"""Flag-gated prompt assertions for the v3 craft guards (issue #72 Phase 3).

Why this test exists
--------------------
The founder's calibration (2026-07-09/10) identified craft defects that recur
*independently of fact quality*: stem answer-leaks, clue-pile stems, telegraphed
true/false, unguessable open numerics, missing post-answer context. Phase 2
taught the reviewer to catch them; Phase 3 teaches the generator to not produce
them — the same rules, injected into the live v3 prompt.

Per the #72 reversibility contract the section ships **dormant behind
`GEN_CRAFT_GUARDS`**: flag off (default) leaves the production prompt
byte-identical; flag on injects the guard block. These assertions lock both
halves in, through the real `_build_batch_prompt` path.
"""

from __future__ import annotations

import pytest

from app.generation.advanced_generator import (
    AdvancedQuestionGenerator,
    _V3_CRAFT_GUARDS_SECTION,
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
    assert use_fact_first is True
    assert prompt_version == "v3_fact_first"
    return prompt


def test_craft_guards_absent_when_flag_off(monkeypatch: pytest.MonkeyPatch) -> None:
    """Default (dormant): production prompt output is unchanged."""
    monkeypatch.delenv("GEN_CRAFT_GUARDS", raising=False)
    prompt = _build_v3_prompt()
    assert "CRAFT GUARDS" not in prompt
    assert "SOURCE FACTS" in prompt  # sanity: the v3 template really rendered


def test_craft_guards_present_when_flag_on(monkeypatch: pytest.MonkeyPatch) -> None:
    """Flag on: every founder-calibrated guard reaches the prompt. One assertion
    per guard so stripping any single rule fails loudly (the 2026-05-20-class
    silent-regression lesson from P2.1)."""
    monkeypatch.setenv("GEN_CRAFT_GUARDS", "1")
    prompt = _build_v3_prompt()
    assert "No stem leak" in prompt
    assert "One sharp hook" in prompt
    assert "Name the wrong assumption" in prompt
    assert "The answer must be gettable" in prompt
    assert "True/false discipline" in prompt
    assert "No unguessable open numeric" in prompt
    assert "Answer context payoff" in prompt
    # Pilot 2026-07-11 R2-Q10: an incidental exact year ("In 1834, …") read
    # unnatural to the founder — decade/era phrasing is the rule, exact year
    # only when the year itself is the question.
    assert "No needless year precision" in prompt
    # Rules 9-12: issue #99, G3 blind-rating 2026-07-15 — both models shared
    # the same four formulation defects (deductive giveaway Q6/Q9/Q8,
    # unanchored referent Q2/Q7/Q10, imperial units Q7, convoluted stem Q9).
    assert "No deductive giveaway" in prompt
    assert "Anchor every referent" in prompt
    assert "Metric-first units" in prompt
    assert "Read-aloud clarity" in prompt


def test_craft_guards_keep_founder_exceptions(monkeypatch: pytest.MonkeyPatch) -> None:
    """The guards must encode the founder's carve-outs, not blanket bans: an
    estimable numeric stays a GOOD open question (heart-beats D4, 5/5), and the
    telegraphed-T/F fix is the transform-to-MCQ, not deletion (Golf Q36)."""
    monkeypatch.setenv("GEN_CRAFT_GUARDS", "on")
    prompt = _build_v3_prompt()
    assert "count your pulse and multiply" in prompt
    assert "How many holes did the Old Course at St Andrews originally have?" in prompt
    # #99 carve-outs: an iconic source figure may keep imperial in parentheses
    # (rule 11), and the answer-cap's evicted context has a sanctioned home in
    # the stem as a neutral anchor (rule 10) — not a blanket ban on context.
    assert "100 °F (38 °C)" in prompt
    assert "NEUTRAL anchor" in prompt


def test_flag_off_prompt_is_byte_identical_minus_the_guards() -> None:
    """Revertibility proof: the flag's ONLY effect is the guard block."""
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
    prompt_off = gen.v3_prompt_builder.build_prompt(craft_guards_section="", **pinned)
    prompt_on = gen.v3_prompt_builder.build_prompt(
        craft_guards_section=_V3_CRAFT_GUARDS_SECTION, **pinned
    )
    assert prompt_on != prompt_off
    assert prompt_on.replace(_V3_CRAFT_GUARDS_SECTION, "") == prompt_off
