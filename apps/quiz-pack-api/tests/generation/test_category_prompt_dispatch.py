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

from types import SimpleNamespace
from unittest.mock import AsyncMock

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


# ---------------------------------------------------------------------------
# Dormancy / fall-through regression (issue #76 F-3a task 4).
#
# The dispatch tested above must be *invisible* everywhere it doesn't apply.
# These three tests pin the negative space — every non-entertainment path stays
# byte-identical to pre-#76 `main`, and a fact-less entertainment order degrades
# cleanly — so the reversibility/dormancy claim in the issue (decision 7) is a
# guarded fact, not an assertion. If a future edit let the dispatch leak into a
# sibling category, shadow the open-shape branch, or raise on the no-facts case,
# exactly one of these fails loudly.
# ---------------------------------------------------------------------------


def test_unregistered_category_falls_through_to_generic_v3() -> None:
    """A fact-first order for a *non*-entertainment category renders through the
    generic v3 path, byte-identically to today — the #76 dispatch must not leak
    into any other category.

    `prompt_version == "v3_fact_first"` (NOT `v3_fact_first_history`) proves the
    registry lookup missed and the `else` arm — i.e. `self.v3_prompt_builder` —
    was selected, exactly as a pre-#76 codebase would. The builder and version
    are set together in that one arm, so an unchanged version *is* proof the
    generic v3 template rendered; the absent `pop-culture` sentinel is the
    belt-and-suspenders check. `use_fact_first is True` documents that the order
    did ride the fact-first branch and fell through *within* it (facts were
    present) — that is the precise dormancy claim.
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
        categories=["history"],
        question_type="text",
        excluded_topics=None,
        avoid_questions=None,
        user_bad_examples=None,
        source_facts=_SOURCE_FACTS,
        mcq_patterns={"odd_one_out"},
    )
    assert use_open is False
    assert use_fact_first is True
    assert prompt_version == "v3_fact_first"
    assert "pop-culture" not in prompt.lower()


def test_no_facts_entertainment_falls_back_to_generic_prompt() -> None:
    """No-facts fall-back (the Rule #1 design choice surfaced as Phase-5 caution
    PC-1): there is deliberately no fact-*less* entertainment prompt —
    entertainment is a fact-first-only variant. An `entertainment` order that
    arrives with no source facts must therefore route to the generic default
    builder, NOT raise and NOT emit entertainment tone.

    With `source_facts=None`, `use_fact_first` is False, so the category dispatch
    — which lives *inside* the fact-first branch — is never consulted: the call
    lands in the final `else`, where `prompt_builder = self.prompt_builder` and
    `prompt_version = self.prompt_version`. Asserting both flags False AND the
    version equal to `gen.prompt_version` uniquely pins that branch (it is the
    only one that returns `self.prompt_version`), which is how we prove "builder
    is `self.prompt_builder`" even though the method doesn't return the builder.
    The call completing at all is the no-exception guarantee: the generic
    template tolerates the omitted `{facts_section}` because it has no such
    placeholder (this is the long-standing default production path).
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
        source_facts=None,
        mcq_patterns=None,
    )
    assert use_open is False
    # `not` (not `is False`): with `source_facts=None` the `and`-chain that
    # computes `use_fact_first` short-circuits to the falsy `None`, never the
    # literal `False`. Downstream uses it only in boolean context, so what
    # matters — and what we pin — is that fact-first is *not active*.
    assert not use_fact_first
    assert prompt_version == gen.prompt_version
    assert "pop-culture" not in prompt.lower()


def test_open_shape_precedence_over_entertainment_dispatch() -> None:
    """The open/logical branch (#46) outranks both fact-first and the #76
    entertainment dispatch. Even with `categories=["entertainment"]` AND source
    facts present, `open_shape=True` must win — open questions are generated from
    the dedicated open prompt, never fact-first, so the entertainment builder
    must not hijack an open order.

    `use_open is True` + `use_fact_first is False` + `prompt_version == "open"`
    pins the first branch; the absent `pop-culture` sentinel proves the
    entertainment template did not render despite the matching category. This
    locks the documented precedence (advanced_generator.py:702-708) so a later
    edit can't let the category dispatch shadow open-shape.
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
        open_shape=True,
    )
    assert use_open is True
    assert use_fact_first is False
    assert prompt_version == "open"
    assert "pop-culture" not in prompt.lower()


# ---------------------------------------------------------------------------
# End-to-end dispatch + category-stamping through `generate_questions`
# (issue #76 F-3a task 5).
#
# The three tests above pin the dispatch at the `_build_batch_prompt` unit. This
# one proves the dispatch's two *observable* effects survive the full public
# `generate_questions` path — internal prompt selection is worthless if the
# stamped provenance/category don't actually reach the returned questions. It is
# the F-3a "small dry-run validation" with the generation LLM stubbed; the paid
# corpus dry-run waits for un-park (parked, out of scope).
# ---------------------------------------------------------------------------


# A two-question batch in the shape `_parse_response` reads. Each question
# *omits* `category` on purpose — see the test docstring for why that omission
# is load-bearing.
_ENTERTAINMENT_BATCH_RESPONSE = """{
  "questions": [
    {
      "id": "q_ent_1",
      "reasoning": {"pattern_used": "open_question", "why_interesting": "x",
        "universal_appeal": "x", "boring_check": "x"},
      "question": "In 1999, which sci-fi film popularised the 'bullet time' effect?",
      "type": "text",
      "correct_answer": "The Matrix",
      "possible_answers": null,
      "alternative_answers": [],
      "topic": "Film",
      "difficulty": "medium",
      "tags": [],
      "language_dependent": false,
      "age_appropriate": "all"
    },
    {
      "id": "q_ent_2",
      "reasoning": {"pattern_used": "open_question", "why_interesting": "x",
        "universal_appeal": "x", "boring_check": "x"},
      "question": "Which band released the 1975 album 'A Night at the Opera'?",
      "type": "text",
      "correct_answer": "Queen",
      "possible_answers": null,
      "alternative_answers": [],
      "topic": "Music & Artists",
      "difficulty": "medium",
      "tags": [],
      "language_dependent": false,
      "age_appropriate": "all"
    }
  ]
}"""


@pytest.mark.asyncio
async def test_entertainment_order_stamps_category_and_version_through_generate_questions() -> None:
    """The dispatch's two observable effects must hold through the *public*
    `generate_questions` entry, not only the internal `_build_batch_prompt` unit.

    With an order of `categories=["entertainment"]` + source facts and the
    generation LLM stubbed to a fixed batch, every returned question must carry
    (1) `generation_metadata.prompt_version == "v3_fact_first_entertainment"`
    — stamped unconditionally in `_finalize_questions` from the dispatched
    version — and (2) `category == "entertainment"`.

    The stub response *omits* each question's `category` field on purpose: that
    is precisely what forces the category to come from `default_category =
    categories[0]` (passed to `_parse_response`; `Question.from_dict` resolves it
    as `data.get("category", default_category)`). Echoing `"entertainment"` in
    the stub would make the assertion pass even if that order-category seam were
    broken — omitting it pins the actual propagation mechanism the issue names.

    `enable_best_of_n=False` keeps the test to the single LLM under test: the
    best-of-N selection layer adds a critique-LLM round-trip but touches neither
    `prompt_version` nor `category`, so the dispatch + stamping path is exercised
    in full without stubbing a second model.
    """
    fake_ainvoke = AsyncMock(
        return_value=SimpleNamespace(content=_ENTERTAINMENT_BATCH_RESPONSE)
    )
    gen = AdvancedQuestionGenerator(
        generation_model="gpt-4o",
        critique_model="gpt-4o-mini",
        prompt_version="v3_fact_first",
    )
    # ChatOpenAI is a Pydantic model that rejects attribute patching; swap the
    # whole LLM for a thin stub exposing only what `_generate_batch` reads
    # (`.ainvoke`, `.temperature`) — the per-file convention in
    # `test_advanced_generator.py`.
    gen.generation_llm = SimpleNamespace(ainvoke=fake_ainvoke, temperature=0.8)

    questions = await gen.generate_questions(
        count=2,
        difficulty="medium",
        categories=["entertainment"],
        source_facts=_SOURCE_FACTS,
        enable_best_of_n=False,
        open_count=0,
    )

    assert len(questions) == 2
    for q in questions:
        # (1) order category propagated to every question via default_category.
        assert q.category == "entertainment"
        assert q.generation_metadata is not None
        # (2) the entertainment prompt_version was stamped end-to-end.
        assert q.generation_metadata.prompt_version == "v3_fact_first_entertainment"
        # The dispatch stayed *inside* the fact-first branch (C-b): the
        # fact-first pipeline tag rode through, proving facts were injected and
        # the generic-default arm was not taken.
        assert q.generation_metadata.pipeline == "fact_first"

    # End-to-end proof the entertainment template actually rendered to the LLM
    # (`pop-culture` appears in neither the generic v3 nor the open template) and
    # that the `{facts_section}` injection still ran (the source fact is present).
    prompt_text = fake_ainvoke.await_args.args[0][0].content
    assert "pop-culture" in prompt_text.lower()
    assert "The Matrix" in prompt_text
