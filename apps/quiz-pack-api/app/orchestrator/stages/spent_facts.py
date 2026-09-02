"""Spent-fact exclusion for top-up rounds (#167, founder directive 2026-09-02).

**Generation must never pay for a question that dedup is guaranteed to kill.**

`DedupStage` enforces "one fact backs at most ONE question per pack" across
top-up rounds (dedup.py:150-174 — the merged list, not just the new batch, is
re-deduped every round). Before this module, top-up rounds still received the
FULL sourced fact list, including the facts already backing surviving
questions, so the generator happily wrote fresh questions on them and dedup
dropped every one as `fact key reuse` — after their generation AND fact-check
had already been billed. Measured in the #167 entertainment pilot
(`docs/testing/runs/167-entertainment-pilot/gen_run_2026-09-01-r3.txt`): 10 of
14 top-up dedup drops were exactly this.

The fix is a pre-generation filter whose predicate MIRRORS dedup's own
same-fact logic, so the two can never disagree: a fact is dropped iff a
question written on it would be dropped by `DedupStage`. Every helper and
threshold below is IMPORTED from `dedup` — never reimplemented (same anti-fork
precedent as `scripts/filter_postcutoff.py`, pinned by a `__module__` test).

Mapping a `Fact` (app/sourcing/models.py) onto the comparison dedup would make
on the not-yet-written question:

- **Fact-key leg.** `_fact_key` is ``(normalized source_url, normalized
  answer)`` — deliberately a PAIR, because one page ("2026 in film") carries
  many distinct facts, so a URL alone is not an identity. A fact has no answer
  yet, so the mirror asks the equivalent question: does this fact share a
  kept question's URL *and* carry that question's answer in its text? If yes,
  a question written on it lands on the identical fact key and dedup drops it.
  Matching is done on `_normalize_answer`-normalized token strings with space
  padding, so "cars" never matches inside "oscars".
  Only `fact.text` is searched, not `excerpt`: an excerpt is raw page prose
  that neighbouring facts from the same URL share, and matching against it
  would evict distinct facts off one source page — the exact over-reach the
  pair-key design exists to avoid.
- **Content-overlap leg.** `_fact_tokens` is the stopword-stripped content
  tokens of question + answer, compared at Jaccard ≥ 0.35. This is the leg
  that catches "same fact, different wording (and different URL)". The fact
  text IS the substance a question would be written from, so it is fed
  through dedup's own `_fact_tokens` (via a duck-typed stand-in) and compared
  against the kept questions' fact tokens at dedup's own threshold.

The filter is deliberately conservative: a fact text is usually longer than
the question+answer written from it, and Jaccard penalises that size
mismatch, so borderline cases stay in the pool. Erring toward keeping a fact
costs at most one dedup drop (today's status quo); erring toward dropping one
would starve generation of usable material.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any, Sequence

from app.orchestrator.stages.dedup import (
    DEFAULT_FACT_JACCARD_THRESHOLD,
    _fact_key,
    _fact_tokens,
    _jaccard,
    _normalize_answer,
    _normalize_url,
)
from quiz_shared.models.question import Question

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class _FactAsQuestion:
    """Duck-typed stand-in that lets dedup's helpers run against a `Fact`.

    `_fact_tokens` reads `.question` and `.correct_answer`; a sourced fact has
    no answer yet, so the hypothetical question is modelled as "text = the
    fact's text, answer unknown". Using the stand-in (rather than a private
    copy of the tokenizer + stopword set) is what keeps this file honest: if
    dedup's tokenization changes, this filter changes with it.
    """

    question: str
    correct_answer: str | None = None


class SpentFactIndex:
    """Fingerprints of the facts already consumed by the kept questions."""

    def __init__(
        self,
        kept_questions: Sequence[Question],
        fact_jaccard_threshold: float = DEFAULT_FACT_JACCARD_THRESHOLD,
    ) -> None:
        self._answers_by_url: dict[str, set[str]] = {}
        for question in kept_questions:
            key = _fact_key(question)
            if key is None:
                continue
            self._answers_by_url.setdefault(key[0], set()).add(key[1])
        self._kept_fact_tokens = [
            tokens
            for tokens in (_fact_tokens(q) for q in kept_questions)
            if tokens
        ]
        self._fact_jaccard_threshold = fact_jaccard_threshold

    def is_spent(self, fact: Any) -> bool:
        """True iff a question written on `fact` would be dropped by dedup."""
        text = getattr(fact, "text", "") or ""

        # Leg 1 — mirrors dedup.py:156-163 (identical fact key).
        source_url = getattr(fact, "source_url", None)
        if source_url:
            answers = self._answers_by_url.get(_normalize_url(source_url))
            if answers:
                # Same normalizer dedup applies to an answer, so the two sides
                # are tokenized identically; the padding makes it a whole-token
                # containment test rather than a substring one.
                haystack = f" {_normalize_answer(text)} "
                if any(f" {answer} " in haystack for answer in answers):
                    return True

        # Leg 2 — mirrors dedup.py:164-174 (content overlap, same fact
        # different wording/URL).
        tokens = _fact_tokens(_FactAsQuestion(question=text))
        return bool(tokens) and any(
            _jaccard(tokens, seen) >= self._fact_jaccard_threshold
            for seen in self._kept_fact_tokens
        )


def filter_spent_facts(
    facts: Sequence[Any],
    kept_questions: Sequence[Question],
    fact_jaccard_threshold: float = DEFAULT_FACT_JACCARD_THRESHOLD,
) -> tuple[list[Any], int]:
    """Drop facts already spent on `kept_questions`.

    Returns ``(remaining_facts, spent_count)``. With no kept questions the
    index matches nothing, so the pool passes through untouched — which is
    why the initial generation round (run before any question exists) is
    unaffected even if this were ever wired there.
    """
    if not facts:
        return list(facts), 0
    index = SpentFactIndex(kept_questions, fact_jaccard_threshold)
    remaining = [fact for fact in facts if not index.is_spent(fact)]
    return remaining, len(facts) - len(remaining)
