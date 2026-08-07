"""Web search fact sourcing via Tavily API."""

import logging
import os
import re
from typing import Optional

from tavily import AsyncTavilyClient

from app.cost_tracking import TAVILY_ADVANCED_SEARCH_CREDITS, add_tavily_credits

from .models import Fact

logger = logging.getLogger(__name__)

# #153 Phase 0.3: source credibility classification — the founder complaint was
# sdbif.org listicle and youtube.com links served as quiz-fact sources. Domains
# below are matched case-insensitively against the extracted (www.-stripped)
# hostname; everything unmatched defaults to "medium" unless it also trips the
# listicle-slug heuristic (an unknown domain whose URL path reads like a
# numbered "X amazing facts" listicle — the sdbif.org example).
_HIGH_CREDIBILITY_DOMAINS = frozenset(
    {
        "wikipedia.org",
        "britannica.com",
        "bbc.com",
        "bbc.co.uk",
        "nationalgeographic.com",
        "smithsonianmag.com",
        "si.edu",
        "nature.com",
        "sciencedaily.com",
        "scientificamerican.com",
        "nasa.gov",
        "noaa.gov",
        "loc.gov",
        "archives.gov",
        "guinnessworldrecords.com",
        "history.com",
        "reuters.com",
        "apnews.com",
    }
)
_HIGH_CREDIBILITY_SUFFIXES = (".gov", ".edu", ".ac.uk")

_LOW_CREDIBILITY_DOMAINS = frozenset(
    {
        "youtube.com",
        "youtu.be",
        "buzzfeed.com",
        "ranker.com",
    }
)
_LOW_CREDIBILITY_PREFIXES = ("pinterest.",)

# Listicle-slug heuristic: an unclassified domain whose URL path contains a
# number alongside one of these "X amazing facts"-style words is treated as
# low credibility (e.g. sdbif.org's
# "72-amazing-human-brain-facts-based-on-the-latest-science").
_LISTICLE_KEYWORDS = frozenset(
    {"amazing", "fun", "interesting", "crazy", "weird", "mind", "blowing", "facts"}
)
_LISTICLE_NUMBER_RE = re.compile(r"(?:^|[/_-])(\d+)(?:[/_-]|$)")


def _looks_like_listicle(url: str) -> bool:
    """True when the URL path reads like a numbered "N amazing facts" slug."""
    from urllib.parse import urlparse

    path = urlparse(url).path.lower()
    if not _LISTICLE_NUMBER_RE.search(path):
        return False
    tokens = re.split(r"[^a-z0-9]+", path)
    return any(tok in _LISTICLE_KEYWORDS for tok in tokens)


def _domain_or_subdomain_of(domain: str, candidates: frozenset[str]) -> bool:
    """True when `domain` is one of `candidates`, or a subdomain of one —
    Tavily results routinely resolve to `en.wikipedia.org`, not the bare
    `wikipedia.org` an equality check would require."""
    return any(domain == c or domain.endswith(f".{c}") for c in candidates)


def classify_credibility(url: str) -> str:
    """Classify a source URL's domain into a "high"/"medium"/"low" tier."""
    domain = _extract_domain(url)

    if domain.endswith(_HIGH_CREDIBILITY_SUFFIXES) or _domain_or_subdomain_of(
        domain, _HIGH_CREDIBILITY_DOMAINS
    ):
        return "high"

    if domain.startswith(_LOW_CREDIBILITY_PREFIXES) or _domain_or_subdomain_of(
        domain, _LOW_CREDIBILITY_DOMAINS
    ):
        return "low"

    if _looks_like_listicle(url):
        return "low"

    return "medium"

# Backend arch review 2026-07-18: repo-conventional HTTP timeout (matches
# quiz_shared.llm.factory's openai_client()) — AsyncTavilyClient's own default
# is 60s, which is too long to hold up a paid generation pipeline stage on a
# stalled connection.
_TAVILY_TIMEOUT_SECONDS = 10.0


class WebSearchSource:
    """Source facts via Tavily web search API."""

    def __init__(self, api_key: Optional[str] = None, news_mode: bool = False):
        self.api_key = api_key or os.getenv("TAVILY_API_KEY")
        if not self.api_key:
            raise ValueError("TAVILY_API_KEY not set")
        self.client = AsyncTavilyClient(api_key=self.api_key)
        # #76 F-3b: recency-aware fact sourcing. When on, the get_facts search
        # asks Tavily for fresh news (topic=news + time_range=week); default off
        # keeps the search call byte-identical (neither param present).
        self.news_mode = news_mode

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
                    news_kwargs = (
                        {"topic": "news", "time_range": "week"}
                        if self.news_mode
                        else {}
                    )
                    results = await self.client.search(
                        query=query,
                        max_results=5,
                        include_answer=True,
                        search_depth="advanced",
                        timeout=_TAVILY_TIMEOUT_SECONDS,
                        **news_kwargs,
                    )
                    add_tavily_credits(TAVILY_ADVANCED_SEARCH_CREDITS)

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
                                credibility=classify_credibility(result.get("url", "")),
                            )
                        )
                except Exception as e:
                    # Broad catch matches the sibling sourcing modules
                    # (opentriviadb_source, wikipedia_source): a single query
                    # failure must not abort the rest of the fan-out loop.
                    logger.warning("Tavily search failed for %r: %s", query, e)
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
                timeout=_TAVILY_TIMEOUT_SECONDS,
            )
            add_tavily_credits(TAVILY_ADVANCED_SEARCH_CREDITS)
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
