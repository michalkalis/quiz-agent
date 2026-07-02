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

        return batch
