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
  "Cited" means *the search tool really fetched that page*: the trusted set
  is the response's ``url_citation`` annotations **plus** the URLs of the
  ``web_search_call`` items the tool actually opened (see
  ``_trusted_urls``). A bare-JSON reply carries no annotations at all
  (measured, 2026-08-31), so annotations alone dropped 100 % of candidates.

#196 track 196.4: the model is the factory ``SOURCING`` role
(``LLM_ROLE_SOURCING``). A ``claude-*`` id runs the same prompt on the
Anthropic Messages API with its server-side ``web_search`` tool (the
``FactVerifier`` pattern); any other id keeps the OpenAI Responses path.
Same integrity rule on both: a fact ships only with a URL the search tool
really returned.

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

# Model swaps need eval data + approval: the factory role's default comes
# from docs/testing/runs/offline-roles-eval-2026-10-10/ (#196 track 196.4).
SOURCING_MODEL = llm_factory.SOURCING

# Anthropic path: searches per topic (each $10/1k) and pause_turn resumes,
# mirroring FactVerifier's bounds so one topic cannot run away.
_MAX_WEB_SEARCHES = 5
_MAX_PAUSE_RESUMES = 2

# Reply budget (reasoning + the JSON array). The fact-check path's 4096 was
# copied here and proved far too small: sourcing spends ~3k tokens on
# reasoning alone before the first fact is written, so five of six #167 pilot
# topics came back ``status="incomplete"`` with nothing usable (measured
# 2026-08-31). 16384 leaves the JSON array room after the reasoning budget.
_MAX_OUTPUT_TOKENS = 16384

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
    """Source facts via a provider's server-side ``web_search`` tool
    (OpenAI Responses, or Anthropic Messages for a ``claude-*`` model)."""

    def __init__(self, model: Optional[str] = None):
        self.model = model or SOURCING_MODEL
        self._anthropic = self.model.startswith("claude")
        # Fail loud at construction, exactly like WebSearchSource does for
        # TAVILY_API_KEY — a keyless source would otherwise degrade into a
        # silent zero-fact leg (the #167 Wikipedia 403 failure mode).
        key = "ANTHROPIC_API_KEY" if self._anthropic else "OPENAI_API_KEY"
        if not os.getenv(key):
            raise ValueError(f"{key} not set")
        # Contract #53: SDK clients come from the factory. Both are
        # direct-provider: no gateway serves either server-side search tool
        # (same carve-out as the fact-check role).
        if self._anthropic:
            self.client = llm_factory.anthropic_client()
        else:
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
                if self._anthropic:
                    facts.extend(
                        await self._anthropic_facts(topic, per_topic_count)
                    )
                    continue
                response = await self.client.responses.create(
                    model=self.model,
                    tools=[{"type": "web_search"}],
                    input=_PROMPT_TEMPLATE.format(
                        count=per_topic_count, topic=topic
                    ),
                    max_output_tokens=_MAX_OUTPUT_TOKENS,
                )
                if getattr(response, "status", None) != "completed":
                    # Carry the reason: an "incomplete" with
                    # reason="max_output_tokens" is a budget problem, not a
                    # search problem, and the bare status hid that for a
                    # whole pilot run.
                    logger.warning(
                        "OpenAI web search for %r ended %r (%s) — no facts taken",
                        topic,
                        getattr(response, "status", None),
                        getattr(response, "incomplete_details", None),
                    )
                    continue
                facts.extend(self._facts_from_response(response, topic))
            except Exception as e:
                # Broad catch matches the sibling sourcing modules: one topic
                # failing must not abort the rest of the fan-out.
                logger.warning("OpenAI web search failed for %r: %s", topic, e)
                continue

        return interleave_by_topic(per_topic_facts)[:count]

    async def _anthropic_facts(self, topic: str, count: int) -> list[Fact]:
        """One Messages turn with ``web_search`` (pause_turn resumed, like
        ``FactVerifier._call_anthropic``); any non-final stop → no facts."""
        prompt = _PROMPT_TEMPLATE.format(count=count, topic=topic)
        tools = [
            {
                "type": "web_search_20260209",
                "name": "web_search",
                "max_uses": _MAX_WEB_SEARCHES,
            }
        ]
        messages = [{"role": "user", "content": prompt}]
        response = None
        for _ in range(1 + _MAX_PAUSE_RESUMES):
            response = await self.client.messages.create(
                model=self.model,
                max_tokens=_MAX_OUTPUT_TOKENS,
                tools=tools,
                messages=messages,
            )
            if response.stop_reason != "pause_turn":
                break
            messages = [
                {"role": "user", "content": prompt},
                {"role": "assistant", "content": response.content},
            ]
        if response is None or response.stop_reason not in ("end_turn", "stop_sequence"):
            logger.warning(
                "Anthropic web search for %r ended %r — no facts taken",
                topic,
                getattr(response, "stop_reason", None),
            )
            return []
        text, urls = _anthropic_text_and_urls(response.content)
        return self._facts_from_text(text, urls, topic)

    def _facts_from_response(self, response, topic: str) -> list[Fact]:
        text, citations = _text_and_citations(response)
        return self._facts_from_text(text, _trusted_urls(response, citations), topic)

    def _facts_from_text(
        self, text: str, citations: list[str], topic: str
    ) -> list[Fact]:
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


def _anthropic_text_and_urls(content) -> tuple[str, list[str]]:
    """Reply text plus every URL the Anthropic ``web_search`` tool returned.

    The trusted set is the ``web_search_tool_result`` hits (pages the search
    really returned) plus any ``web_search_result_location`` citations on the
    text — the Anthropic analogue of ``_trusted_urls``. A tool error result
    is an object, not a list, and contributes nothing.
    """
    text_parts: list[str] = []
    urls: list[str] = []

    def _add(url) -> None:
        if url and url not in urls:
            urls.append(url)

    for block in content or []:
        kind = getattr(block, "type", None)
        if kind == "text":
            text_parts.append(getattr(block, "text", "") or "")
            for citation in getattr(block, "citations", None) or []:
                _add(getattr(citation, "url", None))
        elif kind == "web_search_tool_result":
            results = getattr(block, "content", None)
            if isinstance(results, list):
                for result in results:
                    _add(getattr(result, "url", None))
    return "".join(text_parts), urls


def _trusted_urls(response, citations: list[str]) -> list[str]:
    """``citations`` plus every page the ``web_search`` tool actually opened.

    The Responses API only attaches ``url_citation`` annotations to *prose*
    it cites inline; a reply that is nothing but a JSON array — which is
    exactly what this module asks for — carries none, so annotations alone
    reject every candidate (measured on the #167 pilot: 100 % dropped).

    The ``web_search_call`` items are the stronger anchor anyway: an
    ``open_page``/``find_in_page`` action URL is a page the tool really
    fetched, not a URL the model merely wrote down. The integrity property
    is unchanged — a claimed URL the search tool never visited is still
    rejected, and the URL that ships is still the tool's, never the model's.
    """
    urls = list(citations)
    for item in getattr(response, "output", []) or []:
        if getattr(item, "type", None) != "web_search_call":
            continue
        action = getattr(item, "action", None)
        url = getattr(action, "url", None) if action is not None else None
        if url and url not in urls:
            urls.append(url)
    return urls


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
