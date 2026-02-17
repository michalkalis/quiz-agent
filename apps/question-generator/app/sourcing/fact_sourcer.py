"""Fact sourcer orchestrator — collects facts from all sources and deduplicates."""

import asyncio
from typing import Optional

from .models import Fact, FactBatch
from .wikipedia_source import WikipediaSource
from .opentriviadb_source import OpenTriviaDBSource
from .web_search_source import WebSearchSource
from .news_source import NewsSource
from .czech_slovak_source import CzechSlovakSource


class FactSourcer:
    """Orchestrates fact collection from multiple sources."""

    def __init__(
        self,
        enable_wikipedia: bool = True,
        enable_opentdb: bool = True,
        enable_web_search: bool = False,  # disabled by default (needs API key)
        enable_news: bool = True,
        enable_czech_slovak: bool = True,
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
            self.sources["web_search"] = WebSearchSource()
        if enable_news:
            self.sources["news"] = NewsSource()
        if enable_czech_slovak:
            self.sources["czech_slovak"] = CzechSlovakSource()

    async def gather_facts(
        self,
        count: int = 30,
        topics: Optional[list[str]] = None,
        include_news: bool = True,
    ) -> FactBatch:
        """Gather facts from all enabled sources.

        Args:
            count: Target number of facts to collect
            topics: Optional topic filter
            include_news: Include time-sensitive news facts

        Returns:
            Deduplicated FactBatch with facts from all sources
        """
        per_source = max(count // len(self.sources), 5) if self.sources else 0

        # Gather from all sources concurrently
        tasks = {}
        for name, source in self.sources.items():
            if name == "news" and not include_news:
                continue
            tasks[name] = source.get_facts(count=per_source, topics=topics)

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
