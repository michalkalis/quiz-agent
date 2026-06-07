"""Unit tests for AnswerNormalizer (issue #46 task 46.A2b).

Why these scenarios: the deterministic splitter (46.A2) deliberately never
splits on a bare comma, so over-cap comma-tailed answers reach this LLM
fallback. The normalizer must recover a canonical head when one exists
(the Sahara audit example, where the head is a *paraphrase* not a substring)
and leave genuinely indivisible answers ("Tokyo, Japan") untouched so the
caller drops them rather than mangling a real short answer. Every failure
mode (no model, unparseable response, low confidence, over-cap head) must
fail-safe to None — normalizing to a guess is worse than dropping.
"""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from app.generation.answer_normalizer import AnswerNormalizer, NormalizedAnswer


class _FakeModel:
    """Returns a canned JSON payload keyed on a substring of the prompt."""

    def __init__(self, responses: dict[str, str]) -> None:
        self._responses = responses
        self.calls: list[str] = []

    async def generate_content_async(self, prompt: str):
        self.calls.append(prompt)
        for key, payload in self._responses.items():
            if key in prompt:
                return SimpleNamespace(text=payload)
        raise AssertionError(f"no canned response matched prompt:\n{prompt}")


def _normalizer_with(responses: dict[str, str], **kwargs) -> AnswerNormalizer:
    norm = AnswerNormalizer(gemini_api_key="test-key", **kwargs)
    norm._model = _FakeModel(responses)  # inject, bypass lazy init
    return norm


@pytest.mark.asyncio
async def test_splits_paraphrasable_head() -> None:
    """The Sahara audit example: a verbose comma-only answer whose canonical
    head ("Grassland/savanna") is a paraphrase, not a substring."""
    sahara = "A lush green landscape with flowing rivers, lakes and grazing wildlife"
    norm = _normalizer_with(
        {
            sahara: json.dumps(
                {
                    "divisible": True,
                    "head": "Grassland/savanna",
                    "explanation": "It was a lush green landscape with rivers and lakes.",
                    "confidence": 0.9,
                }
            )
        }
    )

    result = await norm.normalize("What was the Sahara like 6000 years ago?", sahara)

    assert result == NormalizedAnswer(
        head="Grassland/savanna",
        explanation="It was a lush green landscape with rivers and lakes.",
    )


@pytest.mark.asyncio
async def test_leaves_indivisible_answer_untouched() -> None:
    """"Tokyo, Japan" is a single indivisible answer — the model returns
    divisible=false and the normalizer returns None so the caller drops."""
    norm = _normalizer_with(
        {
            "Tokyo, Japan": json.dumps(
                {
                    "divisible": False,
                    "head": None,
                    "explanation": None,
                    "confidence": 0.95,
                }
            )
        }
    )

    result = await norm.normalize("Capital of Japan and its country?", "Tokyo, Japan")

    assert result is None


@pytest.mark.asyncio
async def test_none_when_model_unavailable() -> None:
    """No API key → no model → fail-safe to None (drop), never raises."""
    norm = AnswerNormalizer(gemini_api_key=None)
    norm.gemini_api_key = None  # neutralise any ambient GOOGLE_API_KEY

    assert await norm.normalize("q", "some long answer, with a comma tail") is None


@pytest.mark.asyncio
async def test_none_below_confidence_threshold() -> None:
    """A low-confidence verdict is dropped, not trusted."""
    answer = "Some hedged answer, possibly several things"
    norm = _normalizer_with(
        {
            answer: json.dumps(
                {
                    "divisible": True,
                    "head": "Maybe X",
                    "explanation": "context",
                    "confidence": 0.3,
                }
            )
        },
        min_confidence=0.6,
    )

    assert await norm.normalize("q", answer) is None


@pytest.mark.asyncio
async def test_none_when_head_over_word_cap() -> None:
    """A 'head' that is itself over the word cap is not a canonical answer."""
    answer = "Long winding answer, that goes on and on without a short core"
    norm = _normalizer_with(
        {
            answer: json.dumps(
                {
                    "divisible": True,
                    "head": "one two three four five six seven eight nine ten eleven",
                    "explanation": "ctx",
                    "confidence": 0.9,
                }
            )
        }
    )

    assert await norm.normalize("q", answer) is None


@pytest.mark.asyncio
async def test_none_on_unparseable_response() -> None:
    """A response with no JSON object fails safe to None."""
    answer = "garbled, answer here"
    norm = _normalizer_with({answer: "I could not produce JSON, sorry."})

    assert await norm.normalize("q", answer) is None
