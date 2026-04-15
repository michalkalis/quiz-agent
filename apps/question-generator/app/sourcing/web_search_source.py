"""Web search fact sourcing via Tavily API."""

import os
from typing import Optional

from tavily import AsyncTavilyClient

from .models import Fact


class WebSearchSource:
    """Source facts via Tavily web search API."""

    def __init__(self, api_key: Optional[str] = None):
        self.api_key = api_key or os.getenv("TAVILY_API_KEY")
        if not self.api_key:
            raise ValueError("TAVILY_API_KEY not set")
        self.client = AsyncTavilyClient(api_key=self.api_key)

    async def get_facts(
        self, count: int = 10, topics: Optional[list[str]] = None
    ) -> list[Fact]:
        """Get facts via Tavily web search.

        Searches for surprising/interesting facts about given topics
        and returns them as Fact objects with source attribution.
        """
        if not topics:
            topics = ["science", "history", "geography", "nature"]

        facts: list[Fact] = []
        queries_per_topic = max(1, count // len(topics))

        for topic in topics:
            query_templates = [
                f"surprising facts about {topic} that most people don't know",
                f"interesting {topic} trivia pub quiz",
            ]

            for query in query_templates[:queries_per_topic]:
                try:
                    results = await self.client.search(
                        query=query,
                        max_results=5,
                        include_answer=True,
                        search_depth="advanced",
                    )

                    for result in results.get("results", []):
                        content = result.get("content", "").strip()
                        if not content or len(content) < 30:
                            continue

                        facts.append(
                            Fact(
                                text=content,
                                source_url=result.get("url"),
                                source_name=_extract_domain(result.get("url", "")),
                                excerpt=content[:300],
                                topic=topic.title(),
                                surprise_rating=6.0,
                                tags=[topic.lower()],
                                verified=False,
                            )
                        )
                except Exception as e:
                    print(f"Tavily search failed for '{query}': {e}")
                    continue

        return facts[:count]

    async def verify_claim(
        self, question: str, claimed_answer: str, max_results: int = 5
    ) -> dict:
        """Verify a factual claim by searching for evidence.

        Returns search results that can be used to confirm or deny
        the claimed answer to a question.
        """
        query = f"{question} {claimed_answer}"
        try:
            results = await self.client.search(
                query=query,
                max_results=max_results,
                include_answer=True,
                search_depth="advanced",
            )
            return {
                "answer": results.get("answer"),
                "results": [
                    {
                        "url": r.get("url"),
                        "title": r.get("title"),
                        "content": r.get("content"),
                        "score": r.get("score"),
                    }
                    for r in results.get("results", [])
                ],
            }
        except Exception as e:
            return {"error": str(e), "results": []}


def _extract_domain(url: str) -> str:
    """Extract domain name from URL for source attribution."""
    try:
        from urllib.parse import urlparse

        parsed = urlparse(url)
        domain = parsed.netloc
        if domain.startswith("www."):
            domain = domain[4:]
        return domain or "unknown"
    except Exception:
        return "unknown"
