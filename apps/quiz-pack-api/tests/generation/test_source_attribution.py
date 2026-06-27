"""Per-question source attribution (issue #72).

Why these scenarios:

The bug they guard against: a whole generated pack cited ONE `source_url`
(the first sourced fact) for every question, because the generator emitted no
per-question URL and the orchestrator back-filled the single global fallback.
A pack drawn from varied facts then *looked* 100% military just because the
first fact happened to be a military listicle. The fix links each question to
the specific fact it was built from, within that sub-batch's disjoint slice.

- `test_attribute_sources_assigns_distinct_urls` is the regression test for the
  collapse itself: three questions on three topics, drawn from a three-fact
  slice, must end up with three DISTINCT urls — not one. If attribution ever
  regresses to a single global fact this fails loudly.
- `test_best_matching_fact_picks_overlapping_fact` pins the match signal: the
  fact sharing content words wins over an unrelated fact in the same slice.
- `test_attribute_sources_mcq_path_without_excerpt` covers the MCQ structured
  path, whose schema carries NO `source_excerpt` at all — attribution must fall
  back to the question/answer text and still find the right fact.
- `test_attribute_sources_preserves_model_emitted_url` guards the gap-only
  contract: a url the model itself emitted is never overwritten.
- `test_attribute_sources_slice_local_fallback` proves the no-match fallback is
  the slice's first sourced fact (so F8 still holds) and never None.
- `test_attribute_sources_noop_without_facts` keeps the fact-free / open path
  (source_url stays None → logical-puzzle F8 exemption) untouched.
- `test_attribute_sources_skips_facts_without_url` leaves source_url None when
  the slice has no urls at all, deferring to the orchestrator net + F8 gate.
"""

from __future__ import annotations

import pytest

from app.generation.advanced_generator import (
    AdvancedQuestionGenerator,
    _content_tokens,
)
from app.sourcing.models import Fact
from quiz_shared.models.question import Question


@pytest.fixture(autouse=True)
def _stub_openai_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """ChatOpenAI asserts the key at construction; the LLM is never called."""
    monkeypatch.setenv("OPENAI_API_KEY", "test-key-not-used")


def _generator() -> AdvancedQuestionGenerator:
    return AdvancedQuestionGenerator(
        generation_model="gpt-4o",
        critique_model="gpt-4o-mini",
        prompt_version="v2_cot",
    )


def _q(question: str, *, answer: str = "", excerpt=None, url=None) -> Question:
    return Question.from_dict(
        {
            "question": question,
            "correct_answer": answer,
            "source_excerpt": excerpt,
            "source_url": url,
        }
    )


# Three facts on clearly different topics, each with its own URL — the slice a
# sub-batch would see after `_partition_facts`.
_ROMAN = Fact(
    text="A Roman legion fielded roughly 5000 soldiers at full strength.",
    source_url="https://example.test/roman-army",
    excerpt="Roman legion of 5000 soldiers",
    topic="History",
)
_OCEAN = Fact(
    text="The anglerfish lures prey with a glowing bioluminescent dorsal spine.",
    source_url="https://example.test/anglerfish",
    excerpt="anglerfish glowing lure in the deep ocean",
    topic="Nature",
)
_SPACE = Fact(
    text="Jupiter is the largest planet and has a giant centuries-old storm.",
    source_url="https://example.test/jupiter",
    excerpt="Jupiter largest planet great red spot storm",
    topic="Space",
)


def test_content_tokens_strips_stopwords_and_short_tokens() -> None:
    tokens = _content_tokens("The Roman army was a large force")
    assert "roman" in tokens and "army" in tokens and "large" in tokens
    assert "the" not in tokens and "was" not in tokens  # stopwords gone
    assert "a" not in tokens  # too short


def test_best_matching_fact_picks_overlapping_fact() -> None:
    gen = _generator()
    q = _q(
        "How many soldiers did a Roman legion field?",
        answer="About 5000",
        excerpt="A Roman legion had around 5000 soldiers",
    )
    match = gen._best_matching_fact(q, [_ROMAN, _OCEAN, _SPACE])
    assert match is _ROMAN


def test_attribute_sources_assigns_distinct_urls() -> None:
    """The core regression: a varied pack must not collapse to one URL."""
    gen = _generator()
    questions = [
        _q("How big was a Roman legion?", answer="5000 soldiers",
           excerpt="Roman legion soldiers strength"),
        _q("How does an anglerfish hunt?", answer="A glowing lure",
           excerpt="anglerfish glowing bioluminescent lure prey"),
        _q("Which is the largest planet?", answer="Jupiter",
           excerpt="Jupiter largest planet storm"),
    ]
    gen._attribute_sources(questions, [_ROMAN, _OCEAN, _SPACE])

    urls = [q.source_url for q in questions]
    assert urls == [
        "https://example.test/roman-army",
        "https://example.test/anglerfish",
        "https://example.test/jupiter",
    ]
    # The whole point: not one URL stamped on every question.
    assert len(set(urls)) == 3


def test_attribute_sources_mcq_path_without_excerpt() -> None:
    """MCQ structured output carries no source_excerpt — match on q/answer."""
    gen = _generator()
    q = _q("Which planet is the largest in the solar system?", answer="Jupiter")
    assert q.source_excerpt is None  # the MCQ path emits none
    gen._attribute_sources([q], [_ROMAN, _OCEAN, _SPACE])
    assert q.source_url == "https://example.test/jupiter"
    # gap-fill also supplies an excerpt from the matched fact
    assert q.source_excerpt is not None


def test_attribute_sources_preserves_model_emitted_url() -> None:
    gen = _generator()
    q = _q("Anything", url="https://model.test/already-set",
           excerpt="Jupiter largest planet")
    gen._attribute_sources([q], [_ROMAN, _OCEAN, _SPACE])
    assert q.source_url == "https://model.test/already-set"  # untouched


def test_attribute_sources_slice_local_fallback() -> None:
    """No content overlap → the slice's FIRST sourced fact, never None or the
    global pack head. Keeps F8 satisfied without misattributing across slices."""
    gen = _generator()
    q = _q("Completely unrelated zzzqqq xxyy", answer="vvbb")
    gen._attribute_sources([q], [_OCEAN, _SPACE])
    assert q.source_url == "https://example.test/anglerfish"  # first in slice


def test_attribute_sources_noop_without_facts() -> None:
    gen = _generator()
    q = _q("An invented lateral puzzle with no web source", answer="42")
    gen._attribute_sources(q_list := [q], None)
    assert q_list[0].source_url is None  # open/logical path stays unsourced


def test_attribute_sources_skips_facts_without_url() -> None:
    gen = _generator()
    no_url = Fact(text="Jupiter is the largest planet", source_url=None)
    q = _q("Largest planet?", answer="Jupiter", excerpt="Jupiter largest planet")
    gen._attribute_sources([q], [no_url])
    assert q.source_url is None  # nothing to attribute → defer to F8 gate
