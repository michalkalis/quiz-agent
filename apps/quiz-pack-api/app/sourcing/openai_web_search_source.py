"""Web search fact sourcing via the OpenAI Responses ``web_search`` tool.

#167 D5 (founder decision 2026-08-31): the Tavily pay-as-you-go limit is
exhausted, so the entertainment pilot sources through the provider that is
already proven in this repo — ``gpt-5-mini`` + the Responses ``web_search``
tool, the founder-approved fact-check backend from #166
(``app/verification/fact_verifier.py:142-179``). This module is the sourcing
half of the same integration: same factory client, same model, same
direct-provider carve-out (no gateway serves the server-side search tool).

Interchangeable with ``WebSearchSource`` — ``FactSourcer`` picks one via
``web_search_provider`` and calls the same ``get_facts(count, topics)``.
**Tavily stays the default and the rollback**; nothing here touches it.

Two properties this source must keep:
- **No news mode / no time-range narrowing** (D4). Recency comes from the
  topic list the caller passes, never from a provider-side window.
- **Every fact carries a real cited URL.** Downstream, F8
  (``app/orchestrator/stages/generation.py:547``) and #167 D6's offline
  excerpt join both key on ``source_url``, so a candidate the model states
  without a matching URL citation is dropped rather than emitted URL-less.

Cost is *not* recorded into the order-level signals: this source is the CLI
pilot path (``scripts/source_facts.py``), which has no order to bill. If it
is ever promoted into the order pipeline, wire the #153 usage recorder the
way ``FactVerifier._record_usage_openai`` does.
"""

import json
import logging
import os
from typing import Optional
from urllib.parse import urlparse

from quiz_shared.llm import factory as llm_factory

from .models import Fact, interleave_by_topic
from .web_search_source import _extract_domain, classify_credibility

logger = logging.getLogger(__name__)

# Founder-approved model for web-search-backed calls (#166 provider research,
# 2026-08-26): 7/7 error recall at ~4-5 ¢/call vs 5/7 at ~18 ¢ for the
# previous Sonnet 5 path. Model swaps need eval data + approval.
SOURCING_MODEL = "gpt-5-mini"

# Reply budget (reasoning + the JSON array). Matches the fact-check path's
# 4096, which was never hit across the #166 validation calls.
_MAX_OUTPUT_TOKENS = 4096

# Fewer facts than this per topic and the call is not worth its latency; the
# caller's `count` budget is spread across topics on top of it.
_MIN_FACTS_PER_TOPIC = 3

# Same floor the Tavily source applies to snippet text — a sub-30-char
# "fact" cannot ground a question.
_MIN_FACT_CHARS = 30

_PROMPT_TEMPLATE = """Use web search to find {count} surprising, trivia-worthy facts about: {topic}

Requirements:
- Every fact must come from a page you actually opened with web search, and you must cite that page.
- Prefer authoritative sources (Wikipedia and the sources it cites, official bodies, established outlets) over aggregators or listicles.
- Each fact must stand alone: one specific, checkable sentence — no "did you know", no filler.
- Drop any candidate you cannot attribute to a cited page.

Reply with ONLY a JSON array, no prose and no code fence:
[{{"fact": "<one-sentence fact>", "excerpt": "<the sentence from the cited page that supports it>", "source_url": "<URL of the cited page>"}}]"""


class OpenAIWebSearchSource:
    """Source facts via the OpenAI Responses API's ``web_search`` tool."""

    def __init__(self, model: Optional[str] = None):
        # Fail loud at construction, exactly like WebSearchSource does for
        # TAVILY_API_KEY — a keyless source would otherwise degrade into a
        # silent zero-fact leg (the #167 Wikipedia 403 failure mode).
        if not os.getenv("OPENAI_API_KEY"):
            raise ValueError("OPENAI_API_KEY not set")
        self.model = model or SOURCING_MODEL
        # Contract #53: SDK clients come from the factory. `direct=True`
        # because no OpenAI-compatible gateway serves the server-side
        # web_search tool (same carve-out as the fact-check role).
        self.client = llm_factory.openai_client(
            async_=True,
            direct=True,
            timeout=llm_factory.GENERATION_TIMEOUT,
        )

    async def get_facts(
        self, count: int = 10, topics: Optional[list[str]] = None
    ) -> list[Fact]:
        """Get facts via OpenAI web search — one Responses call per topic.

        Interleaves per-topic results before truncating to ``count``, so the
        truncation never eats whole topics (#153 round-2 lesson, same as the
        Tavily source).
        """
        if not topics:
            topics = ["science", "history", "geography", "nature"]

        per_topic_count = max(_MIN_FACTS_PER_TOPIC, count // len(topics))
        per_topic_facts: list[list[Fact]] = []

        for topic in topics:
            facts: list[Fact] = []
            per_topic_facts.append(facts)
            try:
                response = await self.client.responses.create(
                    model=self.model,
                    tools=[{"type": "web_search"}],
                    input=_PROMPT_TEMPLATE.format(
                        count=per_topic_count, topic=topic
                    ),
                    max_output_tokens=_MAX_OUTPUT_TOKENS,
                )
                if getattr(response, "status", None) != "completed":
                    logger.warning(
                        "OpenAI web search for %r ended %r — no facts taken",
                        topic,
                        getattr(response, "status", None),
                    )
                    continue
                facts.extend(self._facts_from_response(response, topic))
            except Exception as e:
                # Broad catch matches the sibling sourcing modules: one topic
                # failing must not abort the rest of the fan-out.
                logger.warning("OpenAI web search failed for %r: %s", topic, e)
                continue

        return interleave_by_topic(per_topic_facts)[:count]

    def _facts_from_response(self, response, topic: str) -> list[Fact]:
        text, citations = _text_and_citations(response)
        facts: list[Fact] = []

        for item in _parse_fact_array(text):
            if not isinstance(item, dict):
                continue
            fact_text = str(item.get("fact") or "").strip()
            if len(fact_text) < _MIN_FACT_CHARS:
                continue
            # Attribution comes from the response's OWN url_citation
            # annotations, not from the model's prose: a stated URL that the
            # search tool never cited is unverifiable, and an URL-less fact
            # breaks F8 and D6's offline join downstream.
            source_url = _cited_url(item.get("source_url"), citations)
            if source_url is None:
                logger.warning(
                    "Dropping uncited fact for topic %r: %r", topic, fact_text[:80]
                )
                continue

            excerpt = str(item.get("excerpt") or "").strip() or fact_text
            facts.append(
                Fact(
                    text=fact_text,
                    source_url=source_url,
                    source_name=_extract_domain(source_url),
                    excerpt=excerpt[:300],
                    topic=topic.title(),
                    surprise_rating=6.0,
                    tags=[topic.lower()],
                    verified=False,
                    credibility=classify_credibility(source_url),
                )
            )
        return facts


def _text_and_citations(response) -> tuple[str, list[str]]:
    """Message text plus the ordered, deduplicated ``url_citation`` URLs."""
    text_parts: list[str] = []
    urls: list[str] = []
    for item in getattr(response, "output", []) or []:
        if getattr(item, "type", None) != "message":
            continue
        for content in getattr(item, "content", []) or []:
            text_parts.append(getattr(content, "text", "") or "")
            for annotation in getattr(content, "annotations", []) or []:
                if getattr(annotation, "type", None) != "url_citation":
                    continue
                url = getattr(annotation, "url", "") or ""
                if url and url not in urls:
                    urls.append(url)
    return "".join(text_parts), urls


def _parse_fact_array(text: str) -> list:
    """First JSON array in ``text``, or ``[]``.

    The prompt asks for a bare array, but replies can still carry a code
    fence or a leading sentence — scan to the first ``[`` and decode
    leniently, mirroring ``fact_verifier._parse_verdict_json``.
    """
    idx = text.find("[")
    if idx == -1:
        return []
    try:
        data, _ = json.JSONDecoder().raw_decode(text[idx:])
    except ValueError:
        return []
    return data if isinstance(data, list) else []


def _citation_key(url: str) -> Optional[tuple[str, str]]:
    """Comparable (host, path) key, or ``None`` for a non-http(s) URL."""
    parsed = urlparse(str(url))
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        return None
    host = parsed.netloc.lower()
    if host.startswith("www."):
        host = host[4:]
    return host, parsed.path.rstrip("/").lower()


def _cited_url(claimed_url, citations: list[str]) -> Optional[str]:
    """The citation URL matching ``claimed_url``, or ``None`` if uncited.

    Compared on host + path so the model's tidied URL still matches the
    citation's tracking-parameter variant; the returned URL is always the
    citation's, never the model's.
    """
    if not claimed_url:
        return None
    key = _citation_key(claimed_url)
    if key is None:
        return None
    for citation in citations:
        if _citation_key(citation) == key:
            return citation
    return None
