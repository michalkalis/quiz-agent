"""Fact sourcer orchestrator — collects facts from all sources and deduplicates."""

import asyncio
import os
from typing import Optional

from .models import Fact, FactBatch
from .wikipedia_source import WikipediaSource
from .opentriviadb_source import OpenTriviaDBSource
from .web_search_source import WebSearchSource


class FactSourcer:
    """Orchestrates fact collection from multiple sources."""

    def __init__(
        self,
        enable_wikipedia: bool = True,
        enable_opentdb: bool = True,
        enable_web_search: bool = True,  # Tavily API key configured in .env
        wikipedia_languages: Optional[list[str]] = None,
    ):
        self.sources = {}

        if enable_wikipedia:
            self.sources["wikipedia"] = WikipediaSource(
                languages=wikipedia_languages or ["en"]
            )
        if enable_opentdb:
            self.sources["opentdb"] = OpenTriviaDBSource()
        if enable_web_search:
            # #76 F-3b: recency-aware news sourcing, default off. Follows the
            # inline os.getenv() truthy convention used across the gen layer.
            news_mode = (os.getenv("ENABLE_NEWS_SOURCING") or "").strip().lower() in {
                "1",
                "true",
                "yes",
                "on",
            }
            self.sources["web_search"] = WebSearchSource(news_mode=news_mode)

    async def gather_facts(
        self,
        count: int = 30,
        topics: Optional[list[str]] = None,
    ) -> FactBatch:
        """Gather facts from all enabled sources.

        Args:
            count: Target number of facts to collect
            topics: Optional topic filter

        Returns:
            Deduplicated FactBatch with facts from all sources
        """
        per_source = max(count // len(self.sources), 5) if self.sources else 0
        # #153 round-2: the per-source budget must scale with the topic list,
        # or each source's own `facts[:count]` truncation starves every topic
        # after the first few (seed-153 run: 8/10 topics yielded 0 facts
        # because per_source=8 < 10 topics). Guarantee headroom for ~3 facts
        # per topic per source; sources truncate topic-fair on their side.
        if topics:
            per_source = max(per_source, 3 * len(topics))

        # Gather from all sources concurrently
        tasks = {
            name: source.get_facts(count=per_source, topics=topics)
            for name, source in self.sources.items()
        }

        all_facts: list[Fact] = []
        sources_used: list[str] = []

        results = await asyncio.gather(*tasks.values(), return_exceptions=True)

        for name, result in zip(tasks.keys(), results):
            if isinstance(result, Exception):
                print(f"Source '{name}' failed: {result}")
                continue
            if name == "wikipedia":
                # #153 Phase 0.3: Wikipedia is a high-credibility source.
                # Stamped here rather than in wikipedia_source.py (owned by a
                # parallel #153 track) — every Fact it returns defaults to
                # "medium" otherwise. OpenTriviaDB's "medium" default already
                # matches spec, so it needs no stamping.
                for fact in result:
                    fact.credibility = "high"
            all_facts.extend(result)
            sources_used.append(name)
            print(f"Source '{name}': {len(result)} facts")

        batch = FactBatch(
            facts=all_facts,
            sources_used=sources_used,
        )

        # Deduplicate
        batch = batch.deduplicate()
        print(f"After deduplication: {len(batch.facts)} unique facts")

        # #153 Phase 0.2: tally the deduplicated result per requested topic so
        # SourcingStage can see (and resample) a topic that yielded 0 facts.
        # Broad-feed runs (topics=None) have no per-topic signal to tally.
        if topics:
            batch.facts_per_topic = batch.count_by_topic(topics)

        return batch
