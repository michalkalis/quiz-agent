"""Render + content contract for the #76 entertainment generation prompt (F-3a).

Why this test exists
--------------------
`question_generation_entertainment.md` is the first category-specific
generation prompt — a **fact-first variant** of the live v3 prompt
(`question_generation_v3_fact_first.md`). Because it is rendered through the
same `PromptBuilder`, it must keep byte-for-byte placeholder parity with the
fill set `build_prompt` provides (`app/generation/prompt_builder.py:103-127`):
an unknown `{placeholder}` raises `KeyError` the first time a
`category="entertainment"` order renders, which would only surface at
generation time. The render test below catches that statically.

Beyond "it renders", these assertions pin the two things that justify a
separate prompt at all — and that a careless tone edit could silently drop:

1. the **entertainment tone** (pop-culture persona + the four buckets), and
2. the **driving-safety constraints** (no visual-recognition / no list answers /
   absolute year-anchored phrasing) that keep answers speakable hands-free.

If either pillar disappears the prompt is just a renamed v3 and #76's value is
gone; these tests then fail loudly — the same regression guard the v3
engagement-machinery tests provide for the base prompt.
"""

from __future__ import annotations

from pathlib import Path

from app.generation.prompt_builder import PromptBuilder

# Resolve the prompts dir relative to this test file (parents[2] == quiz-pack-api),
# matching how `test_prompt_response_format.py` locates the prompt corpus.
ENTERTAINMENT_PROMPT = (
    Path(__file__).resolve().parents[2]
    / "prompts"
    / "question_generation_entertainment.md"
)

# A distinctive injected fact so the assertion proves the `{facts_section}`
# channel actually reached the rendered output (not just that render succeeded).
_FACT = "FACT: The Matrix was released in 1999."


def _render(**overrides) -> str:
    """Render the entertainment prompt through the real PromptBuilder.

    Mirrors the task-1 verify call exactly: a fact-first render with an explicit
    `category="entertainment"`, an injected source fact, and an empty
    mcq_patterns_section. Any unfilled placeholder raises KeyError right here.
    """
    kwargs = dict(
        count=10,
        categories=["entertainment"],
        facts_section=_FACT,
        mcq_patterns_section="",
    )
    kwargs.update(overrides)
    return PromptBuilder(str(ENTERTAINMENT_PROMPT)).build_prompt(**kwargs)


def test_entertainment_prompt_renders_with_full_placeholder_set() -> None:
    """Placeholder parity: the fact-first render fills every `{...}` with no
    KeyError, and the injected source fact lands in the output — proving the
    `{facts_section}` injection the v3 machinery depends on survived the copy."""
    prompt = _render()
    assert _FACT in prompt


def test_entertainment_prompt_carries_pop_culture_tone() -> None:
    """The tone sentinel plus the four buckets are what make this prompt
    *entertainment* rather than a renamed v3 — the whole point of #76 F-3a."""
    prompt = _render()
    assert "pop-culture" in prompt.lower()
    assert "Music & Artists" in prompt
    assert "TV & Streaming" in prompt
    assert "Viral / Trending" in prompt


def test_entertainment_prompt_enforces_driving_safety() -> None:
    """The driving-safety rules are the reason a distinct entertainment prompt
    exists: answers are spoken at the wheel. Pin each pillar so an edit cannot
    quietly reintroduce visual-recognition, list, or relative-time questions."""
    prompt = _render()
    assert "No visual-recognition questions" in prompt
    assert "No list answers" in prompt
    # Absolute phrasing: dated facts must be year-anchored, never relative-time
    # ("the latest" / "this year's"), which rots silently as the corpus ages.
    assert "anchor every dated fact to an explicit year" in prompt
