"""Unit tests for LogicalConsistencyVerifier (issue #46 task 46.B5).

Why these scenarios: a lateral-thinking puzzle has no web source, so the only
thing that makes its answer "correct" is that it uniquely and deducibly follows
from the setup. The judge must return a `verified` verdict (same shape as
`FactVerifier`) when the answer holds up, surface competing answers into
`alternative_answers` when it doesn't uniquely follow, and — critically —
fail-safe to `uncertain` (never a false `verified`) when the model is absent or
its response is garbage, because shipping an unverifiable puzzle as "verified"
is the exact failure mode this branch exists to prevent.
"""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from app.verification.fact_verifier import VerificationResult
from app.verification.logical_verifier import LogicalConsistencyVerifier


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


def _verifier_with(responses: dict[str, str]) -> LogicalConsistencyVerifier:
    verifier = LogicalConsistencyVerifier(gemini_api_key="test-key")
    verifier._gemini_model = _FakeModel(responses)  # inject, bypass lazy init
    return verifier


@pytest.mark.asyncio
async def test_verified_when_answer_uniquely_follows() -> None:
    """A puzzle whose answer uniquely follows gets a high-confidence verdict in
    the same VerificationResult shape FactVerifier returns."""
    question = "A man pushes his car to a hotel and loses his fortune. What happened?"
    verifier = _verifier_with(
        {
            question: json.dumps(
                {
                    "verdict": "verified",
                    "confidence": 0.9,
                    "reasoning": "It is a Monopoly game; the deduction is unique.",
                    "alternative_answers": [],
                }
            )
        }
    )

    result = await verifier.verify(question, "He is playing Monopoly")

    assert isinstance(result, VerificationResult)
    assert result.verdict == "verified"
    assert result.confidence == 0.9
    assert result.alternative_answers == []


@pytest.mark.asyncio
async def test_uncertain_surfaces_alternative_answers() -> None:
    """When the answer does not uniquely follow, competing answers must land in
    `alternative_answers` so the open branch can persist them."""
    question = "Why might a room full of married people have no married couples?"
    verifier = _verifier_with(
        {
            question: json.dumps(
                {
                    "verdict": "uncertain",
                    "confidence": 0.4,
                    "reasoning": "Several setups satisfy this.",
                    "alternative_answers": [
                        "Each is married to someone not in the room",
                        "They are all widowed",
                    ],
                }
            )
        }
    )

    result = await verifier.verify(question, "Everyone is married to an absent spouse")

    assert result.verdict == "uncertain"
    assert "They are all widowed" in result.alternative_answers


@pytest.mark.asyncio
async def test_uncertain_when_model_unavailable() -> None:
    """No API key → no model → fail-safe to `uncertain` at zero confidence,
    never a false `verified`, and never raises."""
    verifier = LogicalConsistencyVerifier(gemini_api_key=None)
    verifier.gemini_api_key = None  # neutralise any ambient GOOGLE_API_KEY

    result = await verifier.verify("Some puzzle setup?", "Some answer")

    assert result.verdict == "uncertain"
    assert result.confidence == 0.0


@pytest.mark.asyncio
async def test_uncertain_on_unparseable_response() -> None:
    """A response with no JSON object must fail-safe to `uncertain`, not crash."""
    question = "What word becomes shorter when you add two letters to it?"
    verifier = _verifier_with({question: "I think the answer is 'short'."})

    result = await verifier.verify(question, "Short")

    assert result.verdict == "uncertain"
    assert result.confidence < 0.5
