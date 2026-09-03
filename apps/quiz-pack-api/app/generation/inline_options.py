"""Deterministic inline-option normaliser (founder blind rating 2026-09-03).

The 82-question corpus batch rated 9.15/10 but carried a systematic FORMAT
defect: 14 of 70 free-text questions spoke their own options aloud inside the
stem ("...for how long: closer to 400 years, 1,400 years, or 3,800 years?")
while staying ``type="text"``, so the player had to *say* a bucket the voice
grader then had to match, and iOS never showed the option picker. A further
3 MCQs read all four options in the stem AND again from ``possible_answers``.

Both are structural defects a pure function can see, so they are fixed here
rather than by prompt-nagging: the model keeps writing whatever reads best and
the pipeline repairs the shape. This mirrors #160's doctrine — *structure
outranks the label* — one step further: a question that ENUMERATES options is
an MCQ whatever its ``reasoning_pattern`` says.

Conservative by construction. A stem is only rewritten through a residue rule
that is grammatical by construction (drop the tail after the colon; swap a
closed-table trailing sentence), and a question is only converted when its
answer resolves to exactly ONE extracted option (``mcq_answer`` semantics,
plus the "About 3,800 years" ↔ "3,800 years" containment the generator's own
phrasing needs). Anything ambiguous is left untouched and counted.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from collections.abc import Iterable, Sequence
from typing import Any

logger = logging.getLogger(__name__)

KEYS: tuple[str, ...] = ("a", "b", "c", "d", "e", "f")

# Options must stay short spoken fragments. A long or sentence-punctuated
# "option" means the detector grabbed the wrong clause (a narrative setup, a
# True/False preamble), so the whole match is discarded.
_MAX_OPTION_CHARS = 60
_OPTION_REJECT_CHARS = (".", ";", "—", "–", ":")
_MIN_OPTIONS = 2
_MAX_OPTIONS = 4
# 2b: an MCQ stem only gets rewritten when it really is reciting its own
# option list. Two-option stems ("Which is hotter: the Sun or lightning?")
# are excluded on purpose — stripping those leaves a stem with no comparanda.
_MIN_MCQ_STEM_OPTIONS = 3

_ARTICLE_RE = re.compile(r"\b(?:the|a|an)\b", re.IGNORECASE)
# "closer to" is a comparison lead-in shared by the whole list; "about" is
# NOT stripped — it recurs per option ("about an hour, about a day, ...").
_LIST_LEAD_IN_RE = re.compile(r"^clos(?:er|est)\s+to\s+", re.IGNORECASE)
# Split on list commas only. A comma glued to a digit is a thousands
# separator ("1,400 years"), and splitting there invented phantom options.
_LIST_SPLIT_RE = re.compile(r",(?!\d)")
_OR_RE = re.compile(r"\bor\b", re.IGNORECASE)

# --- residue rules: each yields a stem that is grammatical by construction --
#
# Every rule DELETES an enumeration and must leave a question behind, so each
# carries guards that the remainder still asks something. Without them the
# colon rule treats any preamble as the whole stem: "Here's the catch: is a
# tomato a fruit or a vegetable?" became "Here's the catch?" with the real
# question shredded into two options (PR #76 review, finding 2).

# The remainder must still ASK something.
_QUESTION_WORD_RE = re.compile(
    r"\b(?:how|what|which|who|whom|whose|when|where|why|name|guess)\b",
    re.IGNORECASE,
)
# ...and must not end mid-phrase: "...is its total distance closer to: X, Y,
# or Z?" would otherwise leave "...closer to?" behind.
# Prepositions and conjunctions only — a copula ending ("how long would it
# be") is a complete question, and the shapes a trailing "is" would catch
# ("The answer is: X or Y?") are already rejected for having no question word.
_DANGLING_HEAD_RE = re.compile(
    r"\b(?:to|of|than|like|as|at|in|on|by|with|from|and|or|between|about)$",
    re.IGNORECASE,
)
# An "option" opening with a verb or a preposition is a clause the detector cut
# in the wrong place ("is a tomato a fruit", "of books closer to 80"), not an
# answer a player could say.
_OPTION_BAD_OPENER_RE = re.compile(
    r"^(?:is|are|was|were|do|does|did|can|could|will|would|has|have|which|who|"
    r"what|of|in|on|for|with|than|to|by|at|from)\b",
    re.IGNORECASE,
)
# A comparator inside an option means the list started before the comparison
# did ("Is the number of books closer to 80, 800, or 8,000?").
_OPTION_COMPARATOR_RE = re.compile(r"\bclos(?:er|est)\s+to\b", re.IGNORECASE)

# "<stem>: <options>?"  →  "<stem>?"
_COLON_TAIL_RE = re.compile(r"^(?P<head>.+?):\s*(?P<list>[^:?]+?)\s*\?\s*$", re.DOTALL)
# "<stem>: <options>. <closing question>?"  →  "<stem>. <closing question>?"
_COLON_MID_RE = re.compile(
    r"^(?P<head>.+?):\s*(?P<list>[^:?.]+?)\.\s*(?P<tail>[^.?]+\?)\s*$", re.DOTALL
)
# "<setup.> Is it <options>?"  →  "<setup.> Which is it?"  (closed table). The
# comparator is matched INSIDE the pattern so the list is anchored to it; a
# noun phrase between the subject and "closer to" leaves that phrase at the
# head of the list, where the option guards above reject it.
_SENTENCE_TAIL_RE = re.compile(
    r"^(?P<head>.*[.!?])\s+(?P<subject>is it|is the number)\s+"
    r"(?:clos(?:er|est)\s+to\s+)?(?P<list>[^:?]+?)\s*\?\s*$",
    re.IGNORECASE | re.DOTALL,
)
_SENTENCE_TAIL_REPLACEMENT = {"is it": "Which is it?", "is the number": "How many?"}


@dataclass(frozen=True)
class Clause:
    """Extracted options plus the stem they should be spoken from.

    There is no "options without a rewrite" case: converting a question while
    leaving the recitation in its stem just trades defect 2a for defect 2b
    (PR #76 review, finding 3), so a clause the detector cannot rewrite is no
    clause at all.
    """

    options: list[str]
    stem: str


@dataclass(frozen=True)
class Normalisation:
    """What a caller should write back, or why nothing was written."""

    kind: str  # "to_mcq" | "stem_stripped" | "unmatched"
    question: str | None = None
    possible_answers: dict[str, str] | None = None
    correct_answer: str | None = None


@dataclass
class Counts:
    inline_options_to_mcq: int = 0
    stem_options_stripped: int = 0
    inline_options_unmatched: int = 0

    def add(self, other: "Counts") -> None:
        """Accumulate another pass's counts (one per generated sub-batch)."""
        self.inline_options_to_mcq += other.inline_options_to_mcq
        self.stem_options_stripped += other.stem_options_stripped
        self.inline_options_unmatched += other.inline_options_unmatched

    def as_info(self) -> dict[str, int]:
        return {
            "inline_options_to_mcq": self.inline_options_to_mcq,
            "stem_options_stripped": self.stem_options_stripped,
            "inline_options_unmatched": self.inline_options_unmatched,
        }


def _parse_options(raw: str) -> list[str] | None:
    """Split ``"closer to X, Y, or Z"`` into ``["X", "Y", "Z"]``, else None."""
    text = _LIST_LEAD_IN_RE.sub("", raw.strip())
    if not _OR_RE.search(text):
        # An enumeration without alternation is a list of things the question
        # asks ABOUT, not a set of answers to pick from.
        return None
    text = re.sub(r",?\s+or\s+", ", ", text, flags=re.IGNORECASE)
    parts = [p.strip().rstrip(",;:") for p in _LIST_SPLIT_RE.split(text)]
    parts = [p for p in parts if p]
    if not (_MIN_OPTIONS <= len(parts) <= _MAX_OPTIONS):
        return None
    for part in parts:
        if len(part) > _MAX_OPTION_CHARS:
            return None
        if any(ch in part for ch in _OPTION_REJECT_CHARS):
            return None
        if _OPTION_COMPARATOR_RE.search(part):
            return None
    if _OPTION_BAD_OPENER_RE.match(parts[0]):
        return None
    if len({_normalise(p) for p in parts}) != len(parts):
        return None
    return [_capitalise(p) for p in parts]


def _is_still_a_question(text: str) -> bool:
    """Would the residue read as a question on its own?"""
    stripped = text.rstrip().rstrip(",;:")
    return bool(
        stripped
        and _QUESTION_WORD_RE.search(stripped)
        and not _DANGLING_HEAD_RE.search(stripped)
    )


def _capitalise(option: str) -> str:
    """House style for option text (`{"a": "Hundreds of years", ...}`)."""
    return option[:1].upper() + option[1:] if option else option


def _normalise(text: str) -> str:
    """Comparison form: lower-cased, article-free, punctuation-trimmed.

    Articles are dropped everywhere, not just leading: the generator writes
    the answer and the option from the same idea with different determiners
    ("Three times to Moon and back" ↔ "three times to the Moon and back").
    """
    out = (text or "").lower().strip()
    out = _ARTICLE_RE.sub(" ", out)
    out = re.sub(r"[.!?,;:]+$", "", out).strip()
    return re.sub(r"\s+", " ", out)


def _contains_as_word(haystack: str, needle: str) -> bool:
    """``needle in haystack`` on word boundaries — "80" is not in "800".

    Lookarounds, not ``\\b``: an option ending in a non-word character ("60%",
    "3 km/h") has no trailing word boundary, so ``\\b`` never matched it and
    every percentage bucket came back unmatched (PR #76 review, finding 8).
    """
    if not haystack or not needle:
        return False
    return bool(re.search(rf"(?<!\w){re.escape(needle)}(?!\w)", haystack))


def match_option(
    answer: object,
    options: Sequence[str],
    alternative_answers: Iterable[str] | None = None,
) -> int | None:
    """Index of the single option the answer resolves to, else None.

    Exact normalised equality first, then word-boundary containment in either
    direction — which is what carries "About 3,800 years" onto the option
    "3,800 years". Ambiguity (two options hit) resolves to None: a guessed
    key ships a question whose "correct" option is wrong, the one outcome
    worse than leaving the format defect in place.
    """
    if isinstance(answer, list):
        answer = answer[0] if answer else None
    normalised_options = [_normalise(o) for o in options]
    for candidate in [answer, *(alternative_answers or [])]:
        if not isinstance(candidate, str):
            continue
        target = _normalise(candidate)
        if not target:
            continue
        for index, option in enumerate(normalised_options):
            if option and option == target:
                return index
        hits = [
            index
            for index, option in enumerate(normalised_options)
            if option
            and (
                _contains_as_word(target, option) or _contains_as_word(option, target)
            )
        ]
        if len(hits) == 1:
            return hits[0]
    return None


def find_option_clause(question: str) -> Clause | None:
    """Locate an inline option enumeration in ``question``, else None."""
    if not isinstance(question, str) or "?" not in question:
        return None
    text = question.strip()

    match = _COLON_MID_RE.match(text)
    if match:
        options = _parse_options(match.group("list"))
        tail = match.group("tail").strip()
        head = match.group("head").rstrip().rstrip(",;:")
        # The closing clause carries the question here, so it is what must
        # survive as one ("... the other: sharks or trees. Which came first?").
        if options and head and _is_still_a_question(tail):
            return Clause(options, f"{head}. {tail}")

    match = _COLON_TAIL_RE.match(text)
    if match:
        options = _parse_options(match.group("list"))
        head = match.group("head").rstrip().rstrip(",;:")
        if options and _is_still_a_question(head):
            return Clause(options, f"{head}?")

    match = _SENTENCE_TAIL_RE.match(text)
    if match:
        options = _parse_options(match.group("list"))
        if options:
            replacement = _SENTENCE_TAIL_REPLACEMENT[match.group("subject").lower()]
            return Clause(options, f"{match.group('head').strip()} {replacement}")
    return None


def normalise(
    question: str,
    question_type: str | None,
    correct_answer: object,
    possible_answers: dict | None,
    alternative_answers: Iterable[str] | None = None,
) -> Normalisation | None:
    """Repair one question's inline-option defect, or return None (no defect).

    Free text carrying its own options becomes an MCQ; an MCQ reciting its
    own options loses the recitation. Everything else is left alone.
    """
    is_mcq = question_type == "text_multichoice" or bool(possible_answers)
    if is_mcq:
        return _strip_mcq_stem(question, possible_answers)

    clause = find_option_clause(question)
    if clause is None:
        return None
    index = match_option(correct_answer, clause.options, alternative_answers)
    if index is None:
        return Normalisation(kind="unmatched")
    return Normalisation(
        kind="to_mcq",
        question=clause.stem,
        possible_answers={KEYS[i]: opt for i, opt in enumerate(clause.options)},
        correct_answer=clause.options[index],
    )


def _strip_mcq_stem(question: str, possible_answers: dict | None) -> Normalisation | None:
    """Drop an MCQ stem's recitation of its own options (defect 2b)."""
    if not possible_answers or len(possible_answers) < _MIN_MCQ_STEM_OPTIONS:
        return None
    clause = find_option_clause(question)
    if clause is None or clause.stem == question:
        return None
    values = [str(v) for v in possible_answers.values()]
    matched = {
        index
        for option in clause.options
        if (index := match_option(option, values)) is not None
    }
    if len(matched) < _MIN_MCQ_STEM_OPTIONS:
        return None
    return Normalisation(kind="stem_stripped", question=clause.stem)


def apply_to_questions(questions: Sequence[Any]) -> Counts:
    """Normalise ``Question`` objects in place; return the counts to report."""
    counts = Counts()
    for q in questions:
        result = normalise(
            q.question,
            q.type,
            q.correct_answer,
            q.possible_answers,
            q.alternative_answers,
        )
        if result is None:
            continue
        if result.kind == "unmatched":
            counts.inline_options_unmatched += 1
            logger.warning(
                "inline options left untouched id=%s (answer matches no single "
                "option) question=%r answer=%r",
                getattr(q, "id", None),
                q.question,
                q.correct_answer,
            )
            continue
        q.question = result.question
        if result.kind == "to_mcq":
            q.type = "text_multichoice"
            q.possible_answers = result.possible_answers
            q.correct_answer = result.correct_answer
            # Alternatives are a free-text-evaluator concept; the MCQ path
            # routes on `possible_answers` membership, so phrasings of the
            # old open answer are now dead metadata.
            q.alternative_answers = []
            counts.inline_options_to_mcq += 1
        else:
            # Conversions always rewrite the stem, so counting them here too
            # made the two numbers overlap. This one means what it says: MCQs
            # that already had options and merely recited them.
            counts.stem_options_stripped += 1
    return counts
