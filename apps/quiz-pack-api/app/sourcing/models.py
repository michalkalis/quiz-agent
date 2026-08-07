"""Data models for fact sourcing."""

import logging
import re
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

logger = logging.getLogger(__name__)

# RC-2 (#72 P3.2): every source stamps a flat fabricated `surprise_rating` and
# `top_by_surprise()` had zero call sites, so the generation prompt's "prefer
# surprising facts" was a no-op. This free, deterministic heuristic (no per-fact
# LLM) differentiates facts from cheap text signals that correlate with
# surprise, so ranking by it actually surfaces the interesting material.
_SURPRISE_MARKERS = frozenset(
    {
        "most", "least", "largest", "smallest", "biggest", "tiniest", "first",
        "last", "only", "never", "always", "highest", "lowest", "oldest",
        "youngest", "fastest", "slowest", "deepest", "tallest", "longest",
        "shortest", "rarest", "richest", "heaviest", "hottest", "coldest",
        "earliest", "unique", "record", "extinct", "banned",
    }
)
_WORD_RE = re.compile(r"[a-z]+")
_SURPRISE_BASELINE = 4.0  # plain recall facts land just under "surprise ≥ 5"
_MARKER_BONUS = 1.5
_MAX_MARKERS = 3  # cap so one loud fact can't dominate purely on adjectives
_NUMBER_BONUS = 1.0
_REWRAP_PENALTY = 2.0  # the OpenTDB re-wrap shape (RC-1) is known dull

# #153 Phase 0.3: credibility tier ordering for ranking (lower = ranked first)
# and the starvation-guard threshold for dropping low-credibility facts.
_CREDIBILITY_RANK = {"high": 0, "medium": 1, "low": 2}
_STARVATION_MIN_KEPT = 3


def heuristic_surprise(text: str) -> float:
    """Estimate a fact's surprise (1-10) from cheap text signals — no LLM.

    Signals: superlative/extreme words ("largest", "only", "never", …) lift the
    score (capped, so adjectives can't run away); a concrete number lifts it a
    little (quantified facts make sharper, more answerable questions); and the
    OpenTDB re-wrap shape ("The answer to '…' is …", RC-1) is penalised so it
    sinks below genuine facts when ranked.
    """
    lowered = text.lower()
    words = set(_WORD_RE.findall(lowered))
    markers = len(words & _SURPRISE_MARKERS)

    score = _SURPRISE_BASELINE
    score += min(markers, _MAX_MARKERS) * _MARKER_BONUS
    if any(ch.isdigit() for ch in text):
        score += _NUMBER_BONUS
    if lowered.lstrip().startswith("the answer to"):
        score -= _REWRAP_PENALTY

    return max(1.0, min(10.0, score))


@dataclass
class Fact:
    """A verified interesting fact that can be turned into a quiz question."""

    text: str
    source_url: Optional[str] = None
    source_name: str = "unknown"
    excerpt: Optional[str] = None
    topic: str = "General"
    surprise_rating: float = 5.0  # 1-10, how surprising is this fact
    expires_at: Optional[datetime] = None  # for time-sensitive facts
    tags: list[str] = field(default_factory=list)
    language: str = "en"  # source language
    verified: bool = False
    # #153 Phase 0.3: source credibility tier ("high" | "medium" | "low"),
    # stamped by each source (see web_search_source._classify_credibility for
    # the domain rules). Default "medium" — sources that don't classify
    # (Wikipedia/OpenTriviaDB stamp their own tier explicitly) fall here rather
    # than being penalised or trusted by omission.
    credibility: str = "medium"

    def is_expired(self) -> bool:
        """Check if this fact has expired."""
        if self.expires_at is None:
            return False
        return datetime.now() > self.expires_at


@dataclass
class FactBatch:
    """A collection of facts from various sources."""

    facts: list[Fact] = field(default_factory=list)
    sourced_at: datetime = field(default_factory=datetime.now)
    sources_used: list[str] = field(default_factory=list)
    # #153 Phase 0.2: per-topic fact yield, so a topic that sourced 0 facts is
    # visible rather than silently contributing nothing. Populated by
    # `FactSourcer.gather_facts` (via `count_by_topic`) when topics were
    # requested; stays empty ({}) for the broad-feed (no-topics) path and for
    # any test double that doesn't set it.
    facts_per_topic: dict[str, int] = field(default_factory=dict)

    def deduplicate(self, similarity_threshold: float = 0.85) -> "FactBatch":
        """Remove near-duplicate facts based on text similarity."""
        unique: list[Fact] = []
        seen_texts: list[str] = []

        for fact in self.facts:
            normalized = fact.text.lower().strip()
            is_duplicate = False
            for seen in seen_texts:
                # Simple overlap check — for production, use embedding similarity
                words_a = set(normalized.split())
                words_b = set(seen.split())
                if not words_a or not words_b:
                    continue
                overlap = len(words_a & words_b) / max(len(words_a), len(words_b))
                if overlap > similarity_threshold:
                    is_duplicate = True
                    break

            if not is_duplicate:
                unique.append(fact)
                seen_texts.append(normalized)

        return FactBatch(
            facts=unique,
            sourced_at=self.sourced_at,
            sources_used=self.sources_used,
        )

    def filter_by_topic(self, topics: list[str]) -> "FactBatch":
        """Filter facts by topic."""
        topics_lower = [t.lower() for t in topics]
        filtered = [f for f in self.facts if f.topic.lower() in topics_lower]
        return FactBatch(facts=filtered, sourced_at=self.sourced_at, sources_used=self.sources_used)

    def count_by_topic(self, topics: list[str]) -> dict[str, int]:
        """Tally this batch's facts per requested topic (#153 Phase 0.2).

        Case-insensitive match against `fact.topic` — sources vary the case
        (Wikipedia keeps the requested topic verbatim, web search
        title-cases it) — so a topic with facts under a different case still
        counts. Every requested topic gets an entry, defaulting to 0, so a
        topic that sourced nothing is explicit rather than absent.
        """
        counts = {t: 0 for t in topics}
        topics_lower = {t.lower(): t for t in topics}
        for fact in self.facts:
            key = topics_lower.get(fact.topic.lower())
            if key is not None:
                counts[key] += 1
        return counts

    def score_surprise_heuristic(self) -> "FactBatch":
        """Replace each fact's flat surprise_rating with the free text heuristic.

        RC-2 (#72 P3.2): mutates in place and returns self so callers can chain
        `batch.score_surprise_heuristic().top_by_surprise(n)`.
        """
        for fact in self.facts:
            fact.surprise_rating = heuristic_surprise(fact.text)
        return self

    def top_by_surprise(self, n: int) -> list[Fact]:
        """Get top N facts, credibility tier first, then most surprising.

        #153 Phase 0.3: credibility now leads the ranking — a "high" fact
        always outranks a "medium"/"low" one regardless of surprise score —
        with surprise as the tiebreaker within a tier, preserving the
        pre-existing ordering for the common case where every fact defaults
        to "medium".
        """
        sorted_facts = sorted(
            self.facts,
            key=lambda f: (_CREDIBILITY_RANK.get(f.credibility, 1), -f.surprise_rating),
        )
        return sorted_facts[:n]

    def drop_low_credibility_starved(
        self, min_kept: int = _STARVATION_MIN_KEPT
    ) -> tuple["FactBatch", int]:
        """Drop "low"-credibility facts once their topic already has enough
        trustworthy material (#153 Phase 0.3 — the sdbif.org/YouTube listicle
        complaint).

        Per-topic starvation guard: a topic's "low" facts are only dropped
        once that topic already has >= ``min_kept`` "medium"/"high" facts —
        a thin topic keeps its low-credibility facts (logged) rather than
        being left with fewer than ``min_kept`` sourced facts.

        Returns ``(filtered_batch, dropped_count)`` so the caller can surface
        the drop count in telemetry.
        """
        trustworthy_counts: dict[str, int] = {}
        for fact in self.facts:
            if fact.credibility != "low":
                trustworthy_counts[fact.topic] = trustworthy_counts.get(fact.topic, 0) + 1

        kept: list[Fact] = []
        dropped = 0
        for fact in self.facts:
            if fact.credibility == "low" and trustworthy_counts.get(fact.topic, 0) >= min_kept:
                dropped += 1
                continue
            if fact.credibility == "low":
                logger.warning(
                    "Keeping low-credibility fact for topic %r (only %d "
                    "medium/high facts sourced) to avoid starvation: %r",
                    fact.topic,
                    trustworthy_counts.get(fact.topic, 0),
                    fact.source_url,
                )
            kept.append(fact)

        return (
            FactBatch(
                facts=kept,
                sourced_at=self.sourced_at,
                sources_used=self.sources_used,
                facts_per_topic=self.facts_per_topic,
            ),
            dropped,
        )
