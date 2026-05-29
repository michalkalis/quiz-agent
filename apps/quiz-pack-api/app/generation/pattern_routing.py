"""Pattern → question_type routing for MCQ activation (issue #42 task 42.8).

Why this exists: the generator's LLM picks a reasoning pattern per
question (e.g. ``"true_false"``, ``"odd_one_out"``). Some of those
patterns are inherently multiple-choice — a true/false question
without two options to pick between is a free-text question whose
expected answer is the single token ``"True"`` / ``"False"``, which
the voice evaluator handles poorly. ``PATTERNS_TO_MCQ`` names the
patterns where MCQ is the natural fit; ``choose_question_type`` is
how the post-generation type-tagging step in ``GenerationStage``
(42.9a) maps from pattern to ``Question.type``.

This module is intentionally trivial — a constant set and a 2-line
helper — so the routing rule lives in one obvious place and changes
to the set don't require touching the orchestrator stage.
"""

from __future__ import annotations

from typing import Literal


PATTERNS_TO_MCQ: frozenset[str] = frozenset(
    {
        "true_false",
        "odd_one_out",
        "comparison_bet_older_larger",
        "year_guess",
    }
)


def choose_question_type(pattern: str | None) -> Literal["text", "text_multichoice"]:
    """Return the ``Question.type`` value for a generator-emitted pattern.

    ``None`` / unknown / non-mapped patterns return ``"text"`` so the
    routing is fail-safe: a typo in the LLM's pattern label degrades
    to free-form text, not a half-built MCQ missing options.
    """
    if pattern and pattern in PATTERNS_TO_MCQ:
        return "text_multichoice"
    return "text"
