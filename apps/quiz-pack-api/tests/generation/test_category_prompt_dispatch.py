"""Category→prompt dispatch: registry loading (issue #76 F-3a).

Why this test exists
--------------------
F-3a introduces the first *prompt-selecting* use of an order's `category`. Until
now `category` was a pure sourcing signal; this adds a general
`{category: PromptBuilder}` registry (`category_prompt_builders`) loaded in
`AdvancedQuestionGenerator.__init__` from `_CATEGORY_PROMPT_FILES`, behind the
same `os.path.exists` guard as the v3/open builders. The dispatch in
`_build_batch_prompt` (a later F-3a task) selects the registered builder over the
generic v3 one — so the whole feature hinges on the registry actually being
populated at construction.

This test pins that load step: if the entertainment prompt file is renamed/moved
or the registry entry is dropped, generation would silently fall back to the
generic v3 prompt (losing the entertainment tone + driving-safety rules) and the
only symptom would be blander questions in the corpus. Catching it here turns a
silent regression into a loud unit-test failure.

It is also the general-map guarantee in test form: the assertion is on a
*registry keyed by category*, not on an `entertainment`-named attribute — which
is exactly what lets kids/themed register later by adding one line, no new
branch (decisions 3, 2d).
"""

from __future__ import annotations

import pytest

from app.generation.advanced_generator import AdvancedQuestionGenerator
from app.generation.prompt_builder import PromptBuilder


@pytest.fixture(autouse=True)
def _stub_openai_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """Avoid ChatOpenAI's env-var assertion at construction time."""
    monkeypatch.setenv("OPENAI_API_KEY", "test-key-not-used")


def test_entertainment_prompt_registered_at_construction() -> None:
    """The entertainment fact-first prompt loads into the general category
    registry as a usable PromptBuilder, so `_build_batch_prompt` can dispatch to
    it for a `category="entertainment"` order instead of the generic v3 prompt.

    Asserting on the keyed registry (not an `entertainment` attribute) is the
    point: future categories register the same way with no new branch.
    """
    gen = AdvancedQuestionGenerator(
        generation_model="gpt-4o",
        critique_model="gpt-4o-mini",
        prompt_version="v3_fact_first",
    )
    assert "entertainment" in gen.category_prompt_builders
    assert isinstance(gen.category_prompt_builders["entertainment"], PromptBuilder)


# A fact whose `text` carries a distinctive token, so asserting it lands in the
# rendered prompt proves the `{facts_section}` injection still ran *after* the
# dispatch swapped the builder — i.e. the category swap didn't bypass fact-first.
_SOURCE_FACTS = [
    {
        "text": "The film The Matrix was released in 1999.",
        "source_url": "https://example.org/the-matrix",
        "source_name": "Example",
        "topic": "Film",
        "surprise_rating": 8.0,
    }
]


def test_entertainment_order_dispatches_to_entertainment_builder() -> None:
    """The heart of F-3a task 3: a fact-first order with
    `categories=["entertainment"]` must render through the *entertainment*
    builder (distinct `prompt_version`), and — critically (C-b) — still run the
    fact-first `{facts_section}` + `{mcq_patterns_section}` injection so the
    entertainment prompt *composes with* the v3 engagement machinery rather than
    replacing it. The dispatch changes which fact-first builder runs, never
    whether facts/MCQ are injected; if the selection had been placed outside the
    `use_fact_first` branch, the facts/MCQ blocks would silently vanish — these
    three content assertions are what would catch that.
    """
    gen = AdvancedQuestionGenerator(
        generation_model="gpt-4o",
        critique_model="gpt-4o-mini",
        prompt_version="v3_fact_first",
    )
    prompt, prompt_version, use_open, use_fact_first = gen._build_batch_prompt(
        count=10,
        difficulty="medium",
        topics=None,
        categories=["entertainment"],
        question_type="text",
        excluded_topics=None,
        avoid_questions=None,
        user_bad_examples=None,
        source_facts=_SOURCE_FACTS,
        mcq_patterns={"odd_one_out"},
    )
    # Rides the fact-first branch (not open, not the generic default) and stamps
    # the entertainment-specific version so provenance shows which prompt ran.
    assert use_open is False
    assert use_fact_first is True
    assert prompt_version == "v3_fact_first_entertainment"
    # (a) entertainment sentinel — proves the entertainment builder rendered, not v3
    # (`pop-culture` appears in neither the v3 nor the open/default templates).
    assert "pop-culture" in prompt.lower()
    # (b) the injected source fact survived — the `{facts_section}` injection ran.
    assert "The Matrix" in prompt
    # (c) the MCQ activation block rendered — `{mcq_patterns_section}` injection
    # preserved across the dispatch (C-b: changes the builder, not the injection).
    assert "## Multiple-Choice Activation (pattern-driven)" in prompt
    assert "odd_one_out" in prompt
