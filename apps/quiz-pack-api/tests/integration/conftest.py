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
import os
from typing import Iterator

import httpx
import pytest
import respx

# Constructor-time env vars: WebSearchSource raises if TAVILY_API_KEY is missing,
# langchain_openai.ChatOpenAI requires OPENAI_API_KEY. All real HTTPS to these
# providers is mocked by respx — the placeholders never reach the wire.
os.environ.setdefault("TAVILY_API_KEY", "tvly-test-placeholder")
os.environ.setdefault("OPENAI_API_KEY", "sk-test-placeholder")
# #166 increment 2: FactVerifier fail-closes (withholds every question) when
# ANTHROPIC_API_KEY is absent — the placeholder routes it into the mocked
# /v1/messages endpoint instead.
os.environ.setdefault("ANTHROPIC_API_KEY", "sk-ant-test-placeholder")


@pytest.fixture(autouse=True)
def _two_judge_panel(monkeypatch: pytest.MonkeyPatch) -> None:
    """#159 judge quorum: the mocked test env serves only the OpenAI endpoint,
    so the default panel would field a single judge and every question would
    fall below the 2-verdict quorum. Two OpenAI-family ids keep a genuine
    2-judge panel on the one mocked endpoint — the quorum stays enforced
    instead of being rolled back via JUDGE_QUORUM=1."""
    monkeypatch.setenv("JUDGE_MODELS", "gpt-5.6-sol,gpt-4.1-mini")


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


# Per-dimension scorer verdict (2026-07-30 redesign: MultiModelScorer makes
# one call per quality dimension and expects {"score", "reasoning"}). 8 keeps
# every question clear of the gate floor and the veto thresholds.
_DIM_SCORE_PAYLOAD = {"score": 8, "reasoning": "stubbed dimension verdict"}

# Pairwise best-of-N verdict (stage 3 refinement).
_PAIRWISE_PAYLOAD = {"winner": "A", "reason": "stubbed pairwise verdict"}


def _request_prompt_text(body: dict) -> str:
    """Flatten a ChatCompletion request's message contents to one string.

    Handles both plain-string content and the content-parts list shape the
    generator sends when a prompt-cache breakpoint is active.
    """
    chunks: list[str] = []
    for message in body.get("messages", []):
        content = message.get("content", "")
        if isinstance(content, list):
            chunks.extend(
                str(part.get("text", "")) for part in content if isinstance(part, dict)
            )
        else:
            chunks.append(str(content))
    return "\n".join(chunks)


def _pipeline_llm_response(
    request: httpx.Request, generation_payload: dict
) -> httpx.Response:
    """Dispatch one ChatCompletion request to the right canned payload.

    Since the 2026-07-30 model refresh the critique and scorer share one model
    id, so model-name routing can no longer discriminate call sites. Routing
    keys on STRUCTURAL prompt markers instead — each marker is the fixed
    header of exactly one call site (scorer's per-dimension header, the
    pairwise verdict schema, critique_v2's evaluation header); anything else
    is a generation call.
    """
    body = json.loads(request.content)
    model = body.get("model", "")
    prompt = _request_prompt_text(body)
    if "DIMENSION TO SCORE" in prompt:
        content = json.dumps(_DIM_SCORE_PAYLOAD)
    elif '"winner"' in prompt:
        content = json.dumps(_PAIRWISE_PAYLOAD)
    elif "Question to Evaluate" in prompt:
        content = json.dumps(_CRITIQUE_PAYLOAD)
    else:
        content = json.dumps(generation_payload)
    return httpx.Response(200, json=_chat_completion_envelope(content, model))


def _openai_chat_dispatch(request: httpx.Request) -> httpx.Response:
    """Generation + critique + scorer dispatch (3-variant canned questions)."""
    return _pipeline_llm_response(request, _generation_payload())


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


# ---------------------------------------------------------------------------
# Canned payloads (issue #36 task 2.11d — verifier + scorer mocks)
# ---------------------------------------------------------------------------

# Historical shape from the pre-#166 Tavily-based verifier; since #166
# increment 2 verification runs on the Anthropic route above, and this
# payload only serves sourcing's Tavily calls (FactSourcer just needs
# URL-bearing results).
_TAVILY_VERIFY_RESPONSE = {
    "answer": "An octopus has three hearts.",
    "results": [
        {
            "url": "https://example.com/octopus/anatomy",
            "title": "Octopus anatomy primer",
            "content": (
                "Octopuses have three hearts and nine brains, reach with "
                "eight arms lined with suckers that taste food, and have "
                "zero bones in the body — the octopus squirts ink and uses "
                "camouflage to escape."
            ),
            "score": 0.95,
        },
        {
            "url": "https://example.com/marine-bio/cephalopods",
            "title": "Cephalopod circulation",
            "content": (
                "Cephalopod textbooks list three hearts, nine brains, eight "
                "arms with suckers, zero bones, defensive ink, camouflage "
                "skin, and blue blood based on copper hemocyanin as defining "
                "octopus traits."
            ),
            "score": 0.91,
        },
        {
            "url": "https://example.com/zoology/hearts",
            "title": "Animals with multiple hearts",
            "content": (
                "Among invertebrates, the octopus is famous for three hearts, "
                "nine brains, eight arms, suckers, zero bones, ink jets, "
                "instant camouflage, and copper-based hemocyanin making its "
                "blood blue."
            ),
            "score": 0.87,
        },
    ],
}

# Multi-model scorer prompt asks for the six dimensions plus `overall_score`.
# Keeping `overall_score` at 8.5 matches the task spec line (`scores 7.5/8.5`)
# and stays inside the keep-by-default threshold so this fixture exercises a
# pass-through happy path. Single model — `langchain_anthropic` is not in the
# venv so the scorer falls back to OpenAI-only when only OPENAI_API_KEY is set.
_SCORING_PAYLOAD = {
    "conversation_spark": 8,
    "surprise_delight": 9,
    "tellability": 8,
    "driving_friendliness": 9,
    "clever_framing": 8,
    "factual_confidence": 9,
    "overall_score": 8.5,
    "reasoning": "Strong universal-appeal trivia with a verified answer.",
}

# Anthropic Messages envelope — #166 increment 2: this is the fact-check
# route. FactVerifier now calls the direct Anthropic API and parses the
# trailing verdict JSON out of the reply text; an "ok"/high verdict keeps
# every question (the pre-#166 verified branch equivalent).
_FACTCHECK_PAYLOAD = {
    "verdict": "ok",
    "confidence": "high",
    "note": "No problem found; canned integration verdict.",
    "correct_answer": None,
}
_ANTHROPIC_MESSAGES_RESPONSE = {
    "id": "msg_test_123",
    "type": "message",
    "role": "assistant",
    "model": "claude-sonnet-5",
    "stop_reason": "end_turn",
    "content": [{"type": "text", "text": json.dumps(_FACTCHECK_PAYLOAD)}],
    "usage": {"input_tokens": 120, "output_tokens": 180},
}
# #166 provider swap (2026-08-26): the default FACTCHECK backend is the
# OpenAI Responses API (gpt-5-mini + web_search), so the fact-check mock
# lives on ``/v1/responses``; the Anthropic route above stays for the
# claude rollback path.
_OPENAI_RESPONSES_RESPONSE = {
    "id": "resp_test_123",
    "object": "response",
    "created_at": 1756200000,
    "model": "gpt-5-mini",
    "status": "completed",
    "parallel_tool_calls": True,
    "tool_choice": "auto",
    "tools": [],
    "output": [
        {
            "id": "msg_test_123",
            "type": "message",
            "role": "assistant",
            "status": "completed",
            "content": [
                {
                    "type": "output_text",
                    "text": json.dumps(_FACTCHECK_PAYLOAD),
                    "annotations": [],
                }
            ],
        }
    ],
    # Realistic web-grounded token volume (search results land in input
    # tokens). Deliberately NOT tiny: gpt-5-mini is ~12× cheaper than the
    # old Sonnet default, and e2e's cost guardrail asserts total_cost_cents
    # > 0 — a 120-token mock would round the whole pack's cost to zero.
    "usage": {
        "input_tokens": 40_000,
        "output_tokens": 4_000,
        "total_tokens": 44_000,
        "input_tokens_details": {"cached_tokens": 0},
        "output_tokens_details": {"reasoning_tokens": 0},
    },
}


def _scoring_openai_dispatch(request: httpx.Request) -> httpx.Response:
    """OpenAI ChatCompletion stub for the scoring path.

    2026-07-30: the scorer makes one call per dimension and expects a
    {"score", "reasoning"} verdict, so this returns the per-dimension payload
    regardless of model — sufficient for tests that only exercise scoring.
    """
    body = json.loads(request.content)
    model = body.get("model", "gpt-5.6-sol")
    content = json.dumps(_DIM_SCORE_PAYLOAD)
    return httpx.Response(200, json=_chat_completion_envelope(content, model))


def register_verify_score_mocks(router: respx.MockRouter) -> None:
    """Register HTTP routes for the verification + scoring stages.

    - OpenAI ``/v1/responses`` returns the canned "ok"/high fact-check
      verdict, so ``FactVerifier`` (#166, gpt-5-mini default since the
      2026-08-26 provider swap) keeps every question; Anthropic
      ``/v1/messages`` returns the same verdict for the claude rollback path.
    - OpenAI ``/v1/chat/completions`` returns the scoring payload for any
      model — sufficient for ``MultiModelScorer`` with only ``OPENAI_API_KEY``.
    - Tavily ``/search`` stays registered for sourcing-path callers composed
      on top of this group (verification no longer calls Tavily).
    """
    router.post("https://api.tavily.com/search").mock(
        return_value=httpx.Response(200, json=_TAVILY_VERIFY_RESPONSE)
    )
    router.post("https://api.openai.com/v1/chat/completions").mock(
        side_effect=_scoring_openai_dispatch
    )
    router.post("https://api.openai.com/v1/responses").mock(
        return_value=httpx.Response(200, json=_OPENAI_RESPONSES_RESPONSE)
    )
    router.post("https://api.anthropic.com/v1/messages").mock(
        return_value=httpx.Response(200, json=_ANTHROPIC_MESSAGES_RESPONSE)
    )


@pytest.fixture
def verify_score_http_mocks(
    _block_external_http: respx.MockRouter,
) -> respx.MockRouter:
    """Layer verifier + scorer canned routes on the egress-guard router."""
    register_verify_score_mocks(_block_external_http)
    return _block_external_http


# ---------------------------------------------------------------------------
# Composed e2e mocks (issue #36 task 2.11e — full pipeline)
# ---------------------------------------------------------------------------


def _openai_e2e_dispatch(request: httpx.Request) -> httpx.Response:
    """Dispatch OpenAI ChatCompletion across all pipeline call sites.

    Marker-based (see ``_pipeline_llm_response``): generation, critique,
    per-dimension scoring and pairwise ranking all share one endpoint — and
    since the 2026-07-30 refresh critique and scoring share one model id, so
    the structural prompt markers are the only stable discriminator.
    """
    return _pipeline_llm_response(request, _generation_payload())


def register_e2e_mocks(router: respx.MockRouter) -> None:
    """Compose sourcing + generation + verify/score routes for the full pipeline.

    The verifier's Tavily response wins over sourcing's (registered last);
    FactSourcer doesn't care about result content as long as URLs are present,
    while FactVerifier requires three ``three``-bearing results to land on the
    verified branch without Gemini.
    """
    register_sourcing_mocks(router)
    router.post("https://api.tavily.com/search").mock(
        return_value=httpx.Response(200, json=_TAVILY_VERIFY_RESPONSE)
    )
    router.post("https://api.openai.com/v1/chat/completions").mock(
        side_effect=_openai_e2e_dispatch
    )
    router.post("https://api.openai.com/v1/responses").mock(
        return_value=httpx.Response(200, json=_OPENAI_RESPONSES_RESPONSE)
    )
    router.post("https://api.anthropic.com/v1/messages").mock(
        return_value=httpx.Response(200, json=_ANTHROPIC_MESSAGES_RESPONSE)
    )


@pytest.fixture
def e2e_http_mocks(_block_external_http: respx.MockRouter) -> respx.MockRouter:
    """Layer the full pipeline's canned routes on the egress-guard router."""
    register_e2e_mocks(_block_external_http)
    return _block_external_http


# ---------------------------------------------------------------------------
# Full-pack generation mock (#103 F5) — `e2e_http_mocks` returns 3
# near-duplicate question variants per call, which is fine for consumers that
# only assert "≥1 survivor" but means DedupStage's in-batch Jaccard check
# always collapses them to ~1 real question, tripping TopUpStage's 80% floor
# on any real-sized order. 10 GENUINELY distinct phrasings of the SAME
# easy-to-verify fact (all answer "three", which `_TAVILY_VERIFY_RESPONSE`
# already supports) let the first generation pass alone satisfy target_count,
# so TopUpStage does 0 rounds — the intended happy path, not a workaround
# around the floor. Shared here (moved from test_order_e2e.py, 2026-07-27)
# because the generate_pack CLI now runs TopUpStage too (live-run F-b).
# ---------------------------------------------------------------------------

# #153 Phase 0.1 made "one fact backs one question per pack" a hard dedup
# rule (fact key = source_url + answer, plus a 0.35 content-overlap check),
# and CompositionStage caps questions-per-topic. Ten phrasings of ONE fact —
# the previous shape here — now correctly collapses to a single survivor, so
# the fixture carries ten DISTINCT octopus facts instead: distinct answers,
# URLs, and topics. All answers appear verbatim in
# ``_TAVILY_VERIFY_RESPONSE`` contents so ``FactVerifier`` still hits its
# verified branch for every question.
_TOPUP_FRIENDLY_QUESTIONS = [
    (
        "How many hearts pump blood through an octopus?",
        "three",
        ["3"],
        "Marine Biology",
        "https://example.com/octopus-hearts",
    ),
    (
        "Counting the one in its head and one per arm, how many brains does an octopus use?",
        "nine",
        ["9"],
        "Animal Anatomy",
        "https://example.com/octopus-brains",
    ),
    (
        "What colour is octopus blood?",
        "blue",
        [],
        "Biochemistry",
        "https://example.com/octopus-blood",
    ),
    (
        "An octopus reaches for prey with how many arms?",
        "eight",
        ["8"],
        "Ocean Life",
        "https://example.com/octopus-arms",
    ),
    (
        "How many bones support an octopus's body?",
        "zero",
        ["none"],
        "Zoology",
        "https://example.com/octopus-bones",
    ),
    (
        "What does a startled octopus squirt to cover its escape?",
        "ink",
        [],
        "Animal Behaviour",
        "https://example.com/octopus-ink",
    ),
    (
        "Which skill lets an octopus vanish against any seabed?",
        "camouflage",
        [],
        "Natural History",
        "https://example.com/octopus-camouflage",
    ),
    (
        "An octopus tastes its food using what on its arms?",
        "suckers",
        [],
        "Sea Creatures",
        "https://example.com/octopus-suckers",
    ),
    (
        "Which sea creature is nicknamed the escape artist of the aquarium?",
        "octopus",
        [],
        "Aquarium Science",
        "https://example.com/octopus-escape",
    ),
    (
        "Which metal carries oxygen in an octopus's bloodstream?",
        "copper",
        [],
        "Chemistry of Life",
        "https://example.com/octopus-copper",
    ),
]


def _topup_friendly_generation_payload() -> dict:
    questions = [
        {
            "reasoning": {
                "source_fact": f"Octopus fact behind the answer '{answer}'",
                "pattern_used": "Surprising biology",
                "why_interesting": "Overturns a common assumption",
                "universal_appeal": "Anatomy is universally relatable",
                "boring_check": "Pinned to verified zoological fact",
            },
            "question": text,
            "type": "text",
            "correct_answer": answer,
            "possible_answers": None,
            "alternative_answers": alternatives,
            "topic": topic,
            "category": "science",
            "difficulty": "medium",
            "tags": ["zoology", "anatomy"],
            "language_dependent": False,
            "age_appropriate": "all",
            "source_url": url,
            "source_excerpt": f"Octopus fact: {answer}.",
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
        for text, answer, alternatives, topic, url in _TOPUP_FRIENDLY_QUESTIONS
    ]
    return {"questions": questions}


def _topup_friendly_openai_dispatch(request: httpx.Request) -> httpx.Response:
    return _pipeline_llm_response(request, _topup_friendly_generation_payload())


def register_e2e_mocks_full(router: respx.MockRouter) -> None:
    """Like `register_e2e_mocks`, but with the top-up-friendly generation payload.

    A plain function (not just a fixture body) because `tests/worker/` drives
    the same live pipeline through `process_order` and must serve the same
    endpoints — one corpus of canned routes, so both suites drift together
    instead of one rotting behind the other.
    """
    register_sourcing_mocks(router)
    router.post("https://api.tavily.com/search").mock(
        return_value=httpx.Response(200, json=_TAVILY_VERIFY_RESPONSE)
    )
    router.post("https://api.openai.com/v1/chat/completions").mock(
        side_effect=_topup_friendly_openai_dispatch
    )
    router.post("https://api.openai.com/v1/responses").mock(
        return_value=httpx.Response(200, json=_OPENAI_RESPONSES_RESPONSE)
    )
    router.post("https://api.anthropic.com/v1/messages").mock(
        return_value=httpx.Response(200, json=_ANTHROPIC_MESSAGES_RESPONSE)
    )


@pytest.fixture
def e2e_http_mocks_full(_block_external_http):
    """Like `e2e_http_mocks`, but the generation mock returns enough
    genuinely distinct questions for a real-sized order to clear
    TopUpStage's floor on the first pass (see block comment above)."""
    register_e2e_mocks_full(_block_external_http)
    return _block_external_http
