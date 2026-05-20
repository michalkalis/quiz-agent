"""Integration-test conftest — HTTP egress guard + canned route fixtures.

The autouse ``_block_external_http`` fixture wraps every integration test in a
``respx.mock`` context with ``assert_all_mocked=True``. Any HTTPS request made
through ``httpx`` that doesn't match a registered route raises immediately,
which keeps real LLM / Tavily / Wikipedia calls out of CI even if the test
forgets to mock them.

Per-source mock fixtures (``sourcing_http_mocks``, etc.) layer canned routes
on top of the guard. The e2e test in ``test_order_e2e.py`` composes them.
"""

from __future__ import annotations

import json
from typing import Iterator

import httpx
import pytest
import respx


@pytest.fixture(autouse=True)
def _block_external_http() -> Iterator[respx.MockRouter]:
    """Block any unmocked HTTPS request during integration tests.

    Tests that need real routes register them on the yielded ``MockRouter``.
    ``assert_all_called=False`` so unused routes don't fail the test (a route
    group registered by 2.11b may not be hit by every test).
    """
    with respx.mock(assert_all_called=False, assert_all_mocked=True) as router:
        yield router


# ---------------------------------------------------------------------------
# Canned payloads (issue #36 task 2.11b — sourcing-layer mocks)
# ---------------------------------------------------------------------------

# Wikipedia ``action=parse`` returns HTML in ``parse.text.*``. The current
# ``WikipediaSource._get_did_you_know`` regex pulls <li> blocks and treats each
# one as a fact, so two <li>s here translate to two distinct DYK facts.
_WIKI_PARSE_RESPONSE = {
    "parse": {
        "text": {
            "*": (
                "<ul>"
                "<li>Pluto was reclassified as a dwarf planet by the IAU in 2006, "
                "ending its 76-year run as the ninth planet.</li>"
                "<li>Bananas are botanically classified as berries, while strawberries "
                "are not — fruit classification follows seed structure, not size.</li>"
                "</ul>"
            )
        }
    }
}

_WIKI_FEATURED_RESPONSE = {
    "tfa": {
        "extract": (
            "Mount Everest grows about 4 millimetres taller each year. "
            "GPS measurements confirm continued uplift from the Indian plate "
            "pushing into the Eurasian plate."
        ),
        "titles": {"normalized": "Mount Everest"},
        "content_urls": {
            "desktop": {"page": "https://en.wikipedia.org/wiki/Mount_Everest"}
        },
    },
    "mostread": {"articles": []},
}

_WIKI_SEARCH_RESPONSE = {
    "query": {
        "search": [
            {
                "title": "Octopus",
                "snippet": "Octopuses have three hearts and copper-based blue blood.",
            }
        ]
    }
}

_OPENTDB_RESPONSE = {
    "response_code": 0,
    "results": [
        {
            "question": "What is the capital of Australia?",
            "correct_answer": "Canberra",
            "difficulty": "medium",
        }
    ],
}

_TAVILY_RESPONSE = {
    "answer": "Some answer summary.",
    "results": [
        {
            "url": "https://example.com/science-fact",
            "title": "Surprising science fact",
            "content": (
                "Honey never spoils thanks to its low water content and acidic pH, "
                "which together create a hostile environment for bacteria."
            ),
            "score": 0.9,
        }
    ],
}

_RSS_RESPONSE = """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <item>
      <title>Headline news item</title>
      <link>https://example.com/news/article</link>
      <description>A short description of a recent event.</description>
    </item>
  </channel>
</rss>"""


def register_sourcing_mocks(router: respx.MockRouter) -> None:
    """Register canned HTTP responses for every ``FactSourcer`` back-end.

    Covers Wikipedia (parse / search / featured for ``en|sk|cs``),
    OpenTriviaDB, Tavily web search, and the two news RSS feeds.
    """
    router.get(
        url__regex=r"https://(en|sk|cs)\.wikipedia\.org/w/api\.php.*action=parse.*"
    ).mock(return_value=httpx.Response(200, json=_WIKI_PARSE_RESPONSE))
    router.get(
        url__regex=r"https://(en|sk|cs)\.wikipedia\.org/w/api\.php.*action=query.*"
    ).mock(return_value=httpx.Response(200, json=_WIKI_SEARCH_RESPONSE))
    router.get(
        url__regex=r"https://(en|sk|cs)\.wikipedia\.org/api/rest_v1/feed/featured/.*"
    ).mock(return_value=httpx.Response(200, json=_WIKI_FEATURED_RESPONSE))
    router.get(url__regex=r"https://opentdb\.com/api\.php.*").mock(
        return_value=httpx.Response(200, json=_OPENTDB_RESPONSE)
    )
    router.post("https://api.tavily.com/search").mock(
        return_value=httpx.Response(200, json=_TAVILY_RESPONSE)
    )
    router.get(
        url__regex=r"https?://(feeds\.bbci\.co\.uk|www\.rss-bridge\.org)/.*"
    ).mock(return_value=httpx.Response(200, text=_RSS_RESPONSE))


@pytest.fixture
def sourcing_http_mocks(_block_external_http: respx.MockRouter) -> respx.MockRouter:
    """Layer canned sourcing routes on the egress-guard router."""
    register_sourcing_mocks(_block_external_http)
    return _block_external_http


# ---------------------------------------------------------------------------
# Canned payloads (issue #36 task 2.11c — generation + critique mocks)
# ---------------------------------------------------------------------------

# Question payload mirrors what ``AdvancedQuestionGenerator._parse_response``
# expects from the V3 fact-first prompt: top-level ``questions`` list of dicts
# with ``question``, ``correct_answer``, ``type``, ``source_url``, etc.
# Each question text is intentionally distinct from any gold-standard example
# so ``_dedup_against_gold_standard`` (Jaccard ≥ 0.80) keeps them.
def _generation_payload(n: int = 3) -> dict:
    questions = [
        {
            "reasoning": {
                "source_fact": "Octopuses possess three hearts and copper-based hemocyanin",
                "pattern_used": "Surprising biology",
                "why_interesting": "Most people assume one heart",
                "universal_appeal": "Anatomy is universally relatable",
                "boring_check": "Pinned to verified zoological fact",
            },
            "question": f"How many hearts does an octopus have? (variant {i})",
            "type": "text",
            "correct_answer": "three",
            "possible_answers": None,
            "alternative_answers": ["3"],
            "topic": "Biology",
            "category": "science",
            "difficulty": "medium",
            "tags": ["zoology", "anatomy"],
            "language_dependent": False,
            "age_appropriate": "all",
            "source_url": "https://example.com/octopus-hearts",
            "source_excerpt": "Octopuses have three hearts.",
            "self_critique": {
                "surprise_factor": 8,
                "universal_appeal": 9,
                "clever_framing": 7,
                "educational_value": 9,
                "answerability": 9,
                "overall_score": 8.4,
                "reasoning": "Strong universal appeal",
            },
        }
        for i in range(n)
    ]
    return {"questions": questions}


_CRITIQUE_PAYLOAD = {
    "scores": {
        "surprise_factor": 8,
        "universal_appeal": 8,
        "clever_framing": 7,
        "educational_value": 9,
        "clarity": 9,
        "factual_accuracy": 9,
        "answerability": 9,
    },
    "overall_score": 8.4,
    "red_flags": [],
    "strengths": ["clear question", "verified fact"],
    "weaknesses": [],
    "improvement_suggestions": [],
    "verdict": "excellent",
    "reasoning": "Solid question grounded in a sourced fact.",
}


def _chat_completion_envelope(content: str, model: str) -> dict:
    """OpenAI ChatCompletion response envelope wrapping `content`."""
    return {
        "id": "chatcmpl-test-123",
        "object": "chat.completion",
        "created": 1_700_000_000,
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": 100,
            "completion_tokens": 200,
            "total_tokens": 300,
        },
    }


def _openai_chat_dispatch(request: httpx.Request) -> httpx.Response:
    """Pick generation vs critique payload by model name in request body.

    Generator model (``gpt-4o``) → questions JSON.
    Critique model (``gpt-4o-mini``) → critique JSON.
    Pinning by model name keeps the route shape decoupled from prompt text.
    """
    body = json.loads(request.content)
    model = body.get("model", "")
    if "mini" in model:
        content = json.dumps(_CRITIQUE_PAYLOAD)
    else:
        content = json.dumps(_generation_payload())
    return httpx.Response(200, json=_chat_completion_envelope(content, model))


def register_generation_mocks(router: respx.MockRouter) -> None:
    """Register OpenAI ChatCompletion mocks for generation + critique calls.

    Both endpoints are the same URL; ``_openai_chat_dispatch`` discriminates
    by the ``model`` field in the JSON request body.
    """
    router.post("https://api.openai.com/v1/chat/completions").mock(
        side_effect=_openai_chat_dispatch
    )


@pytest.fixture
def generation_http_mocks(_block_external_http: respx.MockRouter) -> respx.MockRouter:
    """Layer canned OpenAI ChatCompletion routes on the egress-guard router."""
    register_generation_mocks(_block_external_http)
    return _block_external_http
