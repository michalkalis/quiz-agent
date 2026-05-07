"""Data models for fact sourcing."""

from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional


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

    def top_by_surprise(self, n: int) -> list[Fact]:
        """Get top N most surprising facts."""
        sorted_facts = sorted(self.facts, key=lambda f: f.surprise_rating, reverse=True)
        return sorted_facts[:n]
