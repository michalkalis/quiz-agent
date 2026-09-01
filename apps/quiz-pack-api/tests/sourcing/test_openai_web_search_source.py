"""#167 D5 — OpenAI Responses `web_search` as a sourcing provider.

Why these scenarios:

- **Attribution is the whole point.** A fact without a `source_url` is dead
  weight downstream: the grounded generation gate F8
  (`app/orchestrator/stages/generation.py:547`) fails the run, and D6's
  offline post-cutoff filter joins facts to questions on URL + excerpt. So a
  model claim the search tool never cited must be **dropped**, never emitted
  URL-less — and the URL that ships is the citation's, not the model's prose.
- **Tavily must stay the default.** The provider switch exists so the pilot
  can run while the Tavily pay-as-you-go limit is exhausted; if the default
  ever flipped, every existing order (prod included) would silently change
  provider.
- **The credibility classifier is shared, not forked.** Both sources must
  tier the same domain identically, or `top_by_surprise` / the
  starvation guard would rank the two providers' facts on different rules.
- **A missing key fails at construction.** The #167 Wikipedia 403 taught
  that a silently-degrading source leg is invisible for a whole pilot run.

No network: the Responses client is replaced with an `AsyncMock` double.
"""

from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from app.sourcing.fact_sourcer import FactSourcer
from app.sourcing.openai_web_search_source import OpenAIWebSearchSource
from app.sourcing.web_search_source import WebSearchSource

WIKI_URL = "https://en.wikipedia.org/wiki/68th_Annual_Grammy_Awards"


def _response(items: list[dict], citations: list[str], status: str = "completed"):
    """Minimal Responses double: one message carrying the JSON array + citations."""
    content = SimpleNamespace(
        type="output_text",
        text=json.dumps(items),
        annotations=[
            SimpleNamespace(type="url_citation", url=url) for url in citations
        ],
    )
    return SimpleNamespace(
        status=status,
        output=[
            SimpleNamespace(type="web_search_call"),
            SimpleNamespace(type="message", content=[content]),
        ],
    )


def _source(monkeypatch: pytest.MonkeyPatch, response) -> OpenAIWebSearchSource:
    monkeypatch.setenv("OPENAI_API_KEY", "test-key")
    source = OpenAIWebSearchSource()
    source.client = SimpleNamespace(
        responses=SimpleNamespace(create=AsyncMock(return_value=response))
    )
    return source


@pytest.mark.asyncio
async def test_cited_facts_carry_url_and_excerpt(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    response = _response(
        [
            {
                "fact": "Kendrick Lamar won Album of the Year at the 68th Grammys.",
                "excerpt": "Album of the Year was awarded to Kendrick Lamar.",
                "source_url": WIKI_URL,
            }
        ],
        citations=[WIKI_URL + "?utm_source=chatgpt.com"],
    )
    source = _source(monkeypatch, response)

    facts = await source.get_facts(count=5, topics=["2026 awards"])

    assert len(facts) == 1
    fact = facts[0]
    # Both fields are load-bearing downstream (F8, D6 offline join).
    assert fact.source_url == WIKI_URL + "?utm_source=chatgpt.com"
    assert fact.excerpt == "Album of the Year was awarded to Kendrick Lamar."
    assert fact.source_name == "en.wikipedia.org"
    # Shared classifier, not a fork: en.wikipedia.org is a "high" tier domain.
    assert fact.credibility == "high"
    assert fact.topic == "2026 Awards"


@pytest.mark.asyncio
async def test_uncited_fact_is_dropped(monkeypatch: pytest.MonkeyPatch) -> None:
    # The model states a plausible URL the search tool never cited, and a
    # second candidate with no URL at all. Emitting either URL-less would
    # break F8 and D6's offline join, so both must vanish.
    response = _response(
        [
            {
                "fact": "An uncited claim about the 68th Grammy Awards ceremony.",
                "excerpt": "Some supporting sentence about the ceremony.",
                "source_url": "https://example.invalid/never-searched",
            },
            {
                "fact": "A second uncited claim about the 68th Grammy Awards.",
                "excerpt": "Another supporting sentence about the ceremony.",
            },
            {
                "fact": "Kendrick Lamar won Album of the Year at the 68th Grammys.",
                "excerpt": "Album of the Year was awarded to Kendrick Lamar.",
                "source_url": WIKI_URL,
            },
        ],
        citations=[WIKI_URL],
    )
    source = _source(monkeypatch, response)

    facts = await source.get_facts(count=5, topics=["2026 awards"])

    assert [f.text for f in facts] == [
        "Kendrick Lamar won Album of the Year at the 68th Grammys."
    ]
    assert all(f.source_url for f in facts)


@pytest.mark.asyncio
async def test_page_the_tool_opened_counts_as_a_citation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Regression, #167 pilot 2026-08-31: this module asks for a bare JSON
    # array, and the Responses API attaches `url_citation` annotations only
    # to inline-cited prose — so a real reply carries NONE and every
    # candidate was dropped, silently starving the whole sourcing run. A
    # page the search tool actually opened is the stronger anchor and must
    # count. The integrity property is unchanged: a URL the tool never
    # visited is still rejected.
    response = SimpleNamespace(
        status="completed",
        output=[
            SimpleNamespace(
                type="web_search_call",
                action=SimpleNamespace(type="open_page", url=WIKI_URL),
            ),
            SimpleNamespace(
                type="message",
                content=[
                    SimpleNamespace(
                        type="output_text",
                        text=json.dumps(
                            [
                                {
                                    "fact": "Kendrick Lamar won Album of the Year at the 68th Grammys.",
                                    "excerpt": "Album of the Year was awarded to Kendrick Lamar.",
                                    "source_url": WIKI_URL,
                                },
                                {
                                    "fact": "A claim pointing at a page the tool never opened.",
                                    "excerpt": "Unsupported sentence.",
                                    "source_url": "https://example.invalid/never-opened",
                                },
                            ]
                        ),
                        annotations=[],
                    )
                ],
            ),
        ],
    )
    source = _source(monkeypatch, response)

    facts = await source.get_facts(count=5, topics=["2026 awards"])

    assert [f.text for f in facts] == [
        "Kendrick Lamar won Album of the Year at the 68th Grammys."
    ]
    assert facts[0].source_url == WIKI_URL


@pytest.mark.asyncio
async def test_reply_budget_leaves_room_after_reasoning(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # `gpt-5-mini` spends ~3k tokens reasoning before writing a fact, so the
    # fact-check path's 4096 truncated the reply and five of six pilot topics
    # returned `status="incomplete"` with nothing usable. The budget must
    # stay well clear of that reasoning floor.
    response = _response([], citations=[])
    source = _source(monkeypatch, response)

    await source.get_facts(count=5, topics=["2026 awards"])

    kwargs = source.client.responses.create.await_args.kwargs
    assert kwargs["max_output_tokens"] >= 8192


@pytest.mark.asyncio
async def test_no_time_range_narrowing_is_requested(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # D4: recency comes from the topic list, never from a provider-side news
    # window. The request must carry the plain web_search tool and nothing else.
    source = _source(monkeypatch, _response([], citations=[]))

    await source.get_facts(count=5, topics=["2026 awards"])

    kwargs = source.client.responses.create.await_args.kwargs
    assert kwargs["tools"] == [{"type": "web_search"}]
    assert "search_context_size" not in kwargs
    assert "filters" not in kwargs


def test_missing_key_fails_at_construction(monkeypatch: pytest.MonkeyPatch) -> None:
    # Mirrors WebSearchSource's TAVILY_API_KEY check: a keyless source would
    # otherwise degrade into a silent zero-fact leg for a whole pilot run.
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)

    with pytest.raises(ValueError, match="OPENAI_API_KEY"):
        OpenAIWebSearchSource()


class TestProviderSwitch:
    def test_default_provider_is_tavily(self, monkeypatch: pytest.MonkeyPatch) -> None:
        # The prod path: every existing caller passes no provider and must keep
        # getting the Tavily source.
        monkeypatch.setenv("TAVILY_API_KEY", "test-key")

        sourcer = FactSourcer(enable_wikipedia=False, enable_opentdb=False)

        assert isinstance(sourcer.sources["web_search"], WebSearchSource)

    def test_openai_provider_selects_the_openai_source(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("OPENAI_API_KEY", "test-key")

        sourcer = FactSourcer(
            enable_wikipedia=False,
            enable_opentdb=False,
            web_search_provider="openai",
        )

        assert isinstance(sourcer.sources["web_search"], OpenAIWebSearchSource)
        # The key stays "web_search" so sources_used and every downstream
        # tally keep reading the same name regardless of provider.
        assert list(sourcer.sources) == ["web_search"]

    def test_unknown_provider_fails_loud(self) -> None:
        with pytest.raises(ValueError, match="unknown web_search_provider"):
            FactSourcer(web_search_provider="brave")
