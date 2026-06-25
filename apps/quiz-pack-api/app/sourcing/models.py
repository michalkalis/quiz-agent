"""Data models for fact sourcing."""

import re
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

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

    def score_surprise_heuristic(self) -> "FactBatch":
        """Replace each fact's flat surprise_rating with the free text heuristic.

        RC-2 (#72 P3.2): mutates in place and returns self so callers can chain
        `batch.score_surprise_heuristic().top_by_surprise(n)`.
        """
        for fact in self.facts:
            fact.surprise_rating = heuristic_surprise(fact.text)
        return self

    def top_by_surprise(self, n: int) -> list[Fact]:
        """Get top N most surprising facts."""
        sorted_facts = sorted(self.facts, key=lambda f: f.surprise_rating, reverse=True)
        return sorted_facts[:n]
