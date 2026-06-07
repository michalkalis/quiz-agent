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


# --- Issue #46 Track B: answer-shape + verification-mode routing ---------
#
# Two independent axes (issue-46 §"Two axes, not one"):
#   - answer_shape:    closed (short canonical answer) vs open (the question
#                      asks for a mechanism/cause/puzzle resolution, so the
#                      answer is inherently a sentence).
#   - verification_mode: factual (web-verifiable via FactVerifier) vs logical
#                      (no web source exists — a lateral puzzle judged by
#                      LogicalConsistencyVerifier).
#
# Both fail-safe (D1/R2): when the signal is weak, treat the question as the
# common, safe case — ``closed`` / ``factual`` — so a mislabelled question
# still gets the short-answer enforcement and web verification it would have
# had before this branch existed. Routing is by question *shape*, not by
# pattern number: 96% of "logical-looking" long answers are really closed
# questions written verbosely (Track A handles those), so only genuine
# open/puzzle framings divert here.

# Generator pattern labels that are inherently open-shape (answer is a
# mechanism/cause/puzzle resolution, not a short canonical token).
OPEN_SHAPE_PATTERNS: frozenset[str] = frozenset(
    {
        "open_question",
        "causal",
        "lateral_thinking",
        "lateral_thinking_puzzle",
        "lateral_puzzle",
    }
)

# The subset of open-shape patterns with no external source to check
# against — they need the logical-consistency judge, not FactVerifier.
# Factual-mechanism patterns (``causal``, ``open_question``) stay
# ``factual``: "Why are Ferraris red?" is web-verifiable.
LOGICAL_VERIFICATION_PATTERNS: frozenset[str] = frozenset(
    {
        "lateral_thinking",
        "lateral_thinking_puzzle",
        "lateral_puzzle",
    }
)

# Question-text openers that signal an open mechanism/cause/hypothetical
# framing regardless of the pattern label. "How many / how old / how far"
# etc. are *quantitative* (closed), so only mechanism-style "how" openers
# count — hence the explicit "how does/do/come/can" prefixes rather than a
# bare "how".
_OPEN_TEXT_PREFIXES: tuple[str, ...] = (
    "why ",
    "how does ",
    "how do ",
    "how come ",
    "how can ",
    "how would ",
    "what if ",
    "what would happen ",
    "what happens when ",
    "what happens if ",
)


def _normalize_pattern(pattern: str | None) -> str:
    """Lower-case and underscore-join a pattern label for set lookup.

    The generator emits patterns both as snake_case (``"true_false"``)
    and as free-text titles (``"Lateral Thinking Puzzle"``); normalize so
    the membership sets above match either form.
    """
    if not pattern:
        return ""
    return "_".join(pattern.strip().lower().split())


def _has_open_framing(question_text: str | None) -> bool:
    if not question_text:
        return False
    text = question_text.strip().lower()
    return text.startswith(_OPEN_TEXT_PREFIXES)


def answer_shape(
    pattern: str | None, question_text: str | None
) -> Literal["closed", "open"]:
    """Classify whether a question's answer is short-canonical or a sentence.

    ``"open"`` iff the pattern is an open-shape pattern *or* the question
    text uses an open mechanism/cause/hypothetical framing. Everything else
    — including Estimation, Comparison Bet, Reverse Engineer, Odd-One-Out,
    True/False, Number Sequence (D1) — is ``"closed"``. Fail-safe to
    ``"closed"`` so a weak signal keeps Track A's short-answer enforcement.
    """
    if _normalize_pattern(pattern) in OPEN_SHAPE_PATTERNS:
        return "open"
    if _has_open_framing(question_text):
        return "open"
    return "closed"


def verification_mode(
    pattern: str | None, question_text: str | None
) -> Literal["factual", "logical"]:
    """Classify which verifier should judge a question.

    ``"logical"`` only for pure lateral-thinking puzzles (no web source
    exists — judged for internal consistency). Factual-mechanism open
    questions stay ``"factual"`` because they *are* web-verifiable (D2).
    Fail-safe to ``"factual"`` (R2): a mislabelled question still gets web
    verification rather than silently skipping it.
    """
    if _normalize_pattern(pattern) in LOGICAL_VERIFICATION_PATTERNS:
        return "logical"
    return "factual"
