"""Unit tests for FactVerifier agreement + hold-for-review (issue #72 P1.2 / RC-9).

Why these scenarios:

The pre-#72 verifier scored agreement with a naive ``answer_lower in content``
substring test. Crisp recall answers ("Starboard") match their source verbatim
and pass; estimation/reasoning answers ("about 4 million") never substring-match
a source that writes the figure as "4,000,000", so they scored agreement=0 and
were dropped at the 0.5 confidence gate. Verification therefore *selected FOR*
boring, first-degree-recall questions — the exact RC-9 failure #72 exists to fix.

- ``test_estimation_answer_agrees_via_numeric_value`: proves the numeric-aware
  agreement lets an estimate pass when sources state the same magnitude
  differently — so it is NOT dropped.
- ``test_judge_unavailable_holds_instead_of_dropping``: when the search/judge
  is unavailable we cannot conclude "wrong"; the question is tagged
  ``held_for_review`` (kept) rather than dropped at confidence 0.
- ``_answer_supported`` / ``_numbers_in`` unit cases pin the strictness contract:
  numeric tolerance for estimates, strict substring for recall answers.
"""

from __future__ import annotations

from typing import Any, Optional

import pytest

from app.verification.fact_verifier import (
    FactVerifier,
    _answer_supported,
    _numbers_in,
)


class _FakeSearch:
    """WebSearchSource double returning a canned ``verify_claim`` payload."""

    def __init__(
        self,
        results: list[dict[str, Any]],
        answer: Optional[str] = None,
        error: Optional[str] = None,
    ) -> None:
        self._payload: dict[str, Any] = {"results": results}
        if answer is not None:
            self._payload["answer"] = answer
        if error is not None:
            self._payload["error"] = error

    async def verify_claim(
        self, question: str, claimed_answer: str, max_results: int = 5
    ) -> dict[str, Any]:
        return self._payload


# --- _numbers_in / _answer_supported: the agreement contract --------------


def test_numbers_in_parses_commas_and_scale_words() -> None:
    assert _numbers_in("4 million") == [4_000_000.0]
    assert 4_000_000.0 in _numbers_in("population is 4,000,000 people")
    assert _numbers_in("3.5 billion") == [3_500_000_000.0]


def test_answer_supported_strict_for_recall_answers() -> None:
    # Non-numeric recall answers keep the strict verbatim-substring test:
    # present -> supported, absent -> not supported (strictness preserved).
    assert _answer_supported("Starboard", "the right side is called starboard") is True
    assert _answer_supported("Starboard", "the left side is called port") is False


def test_answer_supported_numeric_tolerance() -> None:
    # An estimate matches a source stating the same magnitude differently,
    # but not a clearly different figure.
    assert _answer_supported("about 4 million", "the population is 4,000,000") is True
    assert _answer_supported("about 4 million", "the population is 9,000,000") is False


# --- verify(): the drop-prevention contract -------------------------------


@pytest.mark.asyncio
async def test_estimation_answer_agrees_via_numeric_value() -> None:
    """A non-substring estimation answer is NOT dropped: numeric agreement
    lets it reach a 'verified' verdict above the 0.5 gate."""
    verifier = FactVerifier()
    verifier.search = _FakeSearch(  # type: ignore[assignment]
        results=[
            {"url": "u1", "content": "The metro population is 4,000,000 residents.", "score": 0.9},
            {"url": "u2", "content": "About 4 million people live there.", "score": 0.8},
            {"url": "u3", "content": "Census figure: 4,000,000.", "score": 0.85},
        ]
    )

    result = await verifier.verify("How many people live in X?", "about 4 million")

    assert result.verdict == "verified"
    assert result.held_for_review is False
    assert result.confidence >= 0.5  # above VerificationStage drop threshold
    assert all(s["agrees_with_answer"] for s in result.sources)


@pytest.mark.asyncio
async def test_judge_unavailable_holds_instead_of_dropping(monkeypatch) -> None:
    """When sources do not confirm and the judge is unavailable, the verifier
    holds the question for review (kept) rather than dropping it at conf 0."""
    verifier = FactVerifier()
    verifier.search = _FakeSearch(  # type: ignore[assignment]
        results=[
            {"url": "u1", "content": "An article about the city's history and culture.", "score": 0.5},
            {"url": "u2", "content": "No population figure appears here.", "score": 0.4},
            {"url": "u3", "content": "Unrelated content about local tourism.", "score": 0.3},
        ]
    )
    # Judge unavailable: no GOOGLE_API_KEY and not on the OpenRouter gateway.
    monkeypatch.setattr(verifier, "_available", lambda: False)

    result = await verifier.verify("How many people live in X?", "about 4 million")

    assert result.held_for_review is True
    assert result.verdict == "unverified"


@pytest.mark.asyncio
async def test_search_unavailable_holds_instead_of_dropping() -> None:
    """A total search failure is held for review, not dropped at confidence 0."""
    verifier = FactVerifier()
    verifier.search = _FakeSearch(results=[], error="tavily timeout")  # type: ignore[assignment]

    result = await verifier.verify("How many people live in X?", "about 4 million")

    assert result.held_for_review is True
    assert result.confidence == 0.0
    assert result.verdict == "unverified"
