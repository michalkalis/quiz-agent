"""Unit tests for the web-grounded Claude fact-check (#166 increment 2).

Why these scenarios:

The verifier replaced Tavily+arbiter (0/6 recall on 2026-news errors in
D21b) with the validated adversarial Claude+web pattern (6/6). Its contract
with ``VerificationStage`` is numeric: problem verdicts must land BELOW the
0.5 confidence gate (dropped), ``ok`` at or above it (kept), and anything
the checker could not judge must be ``held_for_review`` (withheld,
fail-closed per #158/#147 — an outage is never evidence for or against an
answer, and unchecked content never ships).

- verdict-mapping tests pin that numeric contract per verdict.
- failure-mode tests (API error, refusal, prose reply, unknown verdict,
  missing key) pin fail-closed: every one must hold, never drop or keep.
- the pause_turn test pins the server-side tool-loop resume so a long web
  search turn is continued instead of silently truncated.
"""

from __future__ import annotations

import json
from types import SimpleNamespace
from typing import Any, Optional

import pytest

from app.verification.fact_verifier import FactVerifier, _parse_verdict_json


def _response(
    text: Optional[str],
    stop_reason: str = "end_turn",
    content: Optional[list[Any]] = None,
) -> SimpleNamespace:
    """Minimal Anthropic Message double (content blocks + usage)."""
    if content is None:
        content = []
        if text is not None:
            content = [SimpleNamespace(type="text", text=text)]
    return SimpleNamespace(
        stop_reason=stop_reason,
        content=content,
        usage=SimpleNamespace(input_tokens=100, output_tokens=50),
    )


class _FakeAnthropic:
    """AsyncAnthropic double returning canned responses in order."""

    def __init__(self, responses: list[Any]) -> None:
        self._responses = list(responses)
        self.requests: list[dict[str, Any]] = []
        self.messages = SimpleNamespace(create=self._create)

    async def _create(self, **kwargs: Any) -> Any:
        self.requests.append(kwargs)
        item = self._responses.pop(0)
        if isinstance(item, Exception):
            raise item
        return item


def _verifier(responses: list[Any]) -> tuple[FactVerifier, _FakeAnthropic]:
    verifier = FactVerifier()
    client = _FakeAnthropic(responses)
    verifier._client = client  # type: ignore[assignment]
    return verifier, client


def _verdict_json(verdict: str, confidence: str = "high", **extra: Any) -> str:
    return json.dumps({"verdict": verdict, "confidence": confidence, **extra})


# --- verdict mapping: the numeric contract with VerificationStage ----------


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("confidence", "expected"), [("high", 0.9), ("medium", 0.7), ("low", 0.5)]
)
async def test_ok_verdict_lands_at_or_above_the_gate(confidence, expected) -> None:
    verifier, client = _verifier(
        [_response("Checked the fact.\n" + _verdict_json("ok", confidence))]
    )

    result = await verifier.verify("Q?", "A")

    assert result.verdict == "ok"
    assert result.confidence == pytest.approx(expected)
    assert result.confidence >= 0.5  # VerificationStage keeps it
    assert result.held_for_review is False
    # The adversarial prompt + web_search tool actually went out.
    request = client.requests[0]
    assert request["tools"][0]["type"] == "web_search_20260209"
    assert "Q?" in request["messages"][0]["content"]


@pytest.mark.asyncio
@pytest.mark.parametrize("verdict", ["fact_error", "logic_flaw", "stale"])
async def test_problem_verdicts_land_below_the_gate(verdict) -> None:
    """fact_error/logic_flaw/stale = drop (founder-approved policy 2026-08-24):
    confidence 0.0 puts them under the stage's 0.5 gate without a stage change."""
    verifier, _ = _verifier(
        [
            _response(
                _verdict_json(
                    verdict,
                    note="superseded per https://example.com",
                    correct_answer="B",
                )
            )
        ]
    )

    result = await verifier.verify("Q?", "A")

    assert result.verdict == verdict
    assert result.confidence == 0.0  # below the gate → dropped, not withheld
    assert result.held_for_review is False
    assert result.alternative_answers == ["B"]
    assert "example.com" in result.notes


@pytest.mark.asyncio
async def test_json_is_found_after_prose_and_citations() -> None:
    """Real replies carry search narration (which may contain braces) before
    the trailing verdict object — the parser must take the LAST verdict JSON."""
    text = (
        'I searched {"query": "test"} and found sources.\n'
        "The answer holds.\n" + _verdict_json("ok", "medium")
    )
    verifier, _ = _verifier([_response(text)])

    result = await verifier.verify("Q?", "A")

    assert result.verdict == "ok"
    assert result.confidence == pytest.approx(0.7)


# --- fail-closed: could-not-check must hold, never drop or keep ------------


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "responses",
    [
        [TimeoutError("anthropic timed out")],
        [_response(None, stop_reason="refusal")],
        [_response("I could not reach a conclusion, sorry.")],
        [_response(_verdict_json("maybe_wrong"))],
    ],
    ids=["api_error", "refusal", "prose_no_json", "unknown_verdict"],
)
async def test_failures_hold_instead_of_dropping(responses) -> None:
    verifier, _ = _verifier(responses)

    result = await verifier.verify("Q?", "A")

    assert result.held_for_review is True
    assert result.verdict == "unverified"
    assert result.confidence == 0.0


@pytest.mark.asyncio
async def test_missing_api_key_holds_without_calling_api(monkeypatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    verifier = FactVerifier()

    result = await verifier.verify("Q?", "A")

    assert result.held_for_review is True
    assert "ANTHROPIC_API_KEY" in result.notes


# --- cost accounting -------------------------------------------------------


@pytest.mark.asyncio
async def test_cost_covers_tokens_and_web_searches() -> None:
    """The direct-Anthropic path is invisible to Tavily/OpenRouter cost
    signals — each verdict must carry its own cost (tokens + $10/1k searches)
    so total_cost_cents doesn't silently lose the verify stage."""
    resp = _response(_verdict_json("ok"))
    resp.usage = SimpleNamespace(
        input_tokens=1_000_000,
        output_tokens=0,
        server_tool_use=SimpleNamespace(web_search_requests=3),
    )
    verifier, _ = _verifier([resp])

    result = await verifier.verify("Q?", "A")

    # 1M input tokens at $3/1M = 300¢, plus 3 searches at 1¢.
    assert result.cost_cents == pytest.approx(303.0)


# --- pause_turn: server-side tool loop resume ------------------------------


@pytest.mark.asyncio
async def test_pause_turn_is_resumed() -> None:
    paused = _response(None, stop_reason="pause_turn")
    paused.content = [SimpleNamespace(type="server_tool_use", text="")]
    verifier, client = _verifier([paused, _response(_verdict_json("ok"))])

    result = await verifier.verify("Q?", "A")

    assert result.verdict == "ok"
    assert len(client.requests) == 2
    # The resume re-sends the paused assistant turn so the server continues.
    resumed = client.requests[1]["messages"]
    assert resumed[1]["role"] == "assistant"
    assert resumed[1]["content"] is paused.content


@pytest.mark.asyncio
async def test_endless_pause_turn_holds() -> None:
    paused = _response(None, stop_reason="pause_turn")
    verifier, _ = _verifier([paused] * 10)

    result = await verifier.verify("Q?", "A")

    assert result.held_for_review is True


# --- _parse_verdict_json ---------------------------------------------------


def test_parse_verdict_json_handles_fences_and_absence() -> None:
    assert _parse_verdict_json('```json\n{"verdict": "ok"}\n```')["verdict"] == "ok"
    assert _parse_verdict_json("no json here") is None
    assert _parse_verdict_json('broken {"verdict": ') is None
