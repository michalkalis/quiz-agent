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
- the session tests (#169) pin the subscription transport: same prompt and
  same contract as the API branches, reachable with no provider key, free.
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
    # Explicit claude model: since the 2026-08-26 provider swap the default
    # FACTCHECK backend is OpenAI — these tests pin the Anthropic path.
    verifier = FactVerifier(model="claude-sonnet-5")
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
@pytest.mark.parametrize(
    ("model", "key"),
    [("claude-sonnet-5", "ANTHROPIC_API_KEY"), ("gpt-5-mini", "OPENAI_API_KEY")],
)
async def test_missing_api_key_holds_without_calling_api(
    monkeypatch, model, key
) -> None:
    monkeypatch.delenv(key, raising=False)
    verifier = FactVerifier(model=model)

    result = await verifier.verify("Q?", "A")

    assert result.held_for_review is True
    assert key in result.notes


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


# --- OpenAI Responses path (#166 provider swap, 2026-08-26) ----------------
#
# The default FACTCHECK backend is now gpt-5-mini + the Responses web_search
# tool (7/7 recall @ ~4 ¢/q on the founder reference vs 5/7 @ ~18 ¢/q for
# Sonnet 5). Same numeric contract and the same fail-closed policy as the
# Anthropic path; ``claude*`` ids keep routing to the Anthropic client
# (rollback lever LLM_ROLE_FACTCHECK=claude-sonnet-5).


def _openai_response(
    text: Optional[str],
    status: str = "completed",
    n_searches: int = 0,
    input_tokens: int = 100,
    output_tokens: int = 50,
) -> SimpleNamespace:
    """Minimal OpenAI Responses double (output items + usage)."""
    output: list[Any] = [
        SimpleNamespace(type="web_search_call") for _ in range(n_searches)
    ]
    if text is not None:
        output.append(
            SimpleNamespace(
                type="message",
                content=[SimpleNamespace(type="output_text", text=text)],
            )
        )
    return SimpleNamespace(
        status=status,
        output=output,
        usage=SimpleNamespace(input_tokens=input_tokens, output_tokens=output_tokens),
    )


class _FakeOpenAI:
    """AsyncOpenAI double returning canned Responses in order."""

    def __init__(self, responses: list[Any]) -> None:
        self._responses = list(responses)
        self.requests: list[dict[str, Any]] = []
        self.responses = SimpleNamespace(create=self._create)

    async def _create(self, **kwargs: Any) -> Any:
        self.requests.append(kwargs)
        item = self._responses.pop(0)
        if isinstance(item, Exception):
            raise item
        return item


def _openai_verifier(responses: list[Any]) -> tuple[FactVerifier, _FakeOpenAI]:
    verifier = FactVerifier(model="gpt-5-mini")
    client = _FakeOpenAI(responses)
    verifier._client = client  # type: ignore[assignment]
    return verifier, client


@pytest.mark.asyncio
async def test_openai_ok_verdict_keeps_and_sends_web_search_tool() -> None:
    verifier, client = _openai_verifier(
        [_openai_response("Checked.\n" + _verdict_json("ok"), n_searches=2)]
    )

    result = await verifier.verify("Q?", "A")

    assert result.verdict == "ok"
    assert result.confidence == pytest.approx(0.9)
    assert result.held_for_review is False
    request = client.requests[0]
    assert request["tools"] == [{"type": "web_search"}]
    assert "Q?" in request["input"]


@pytest.mark.asyncio
async def test_openai_problem_verdict_lands_below_the_gate() -> None:
    verifier, _ = _openai_verifier(
        [
            _openai_response(
                _verdict_json("fact_error", correct_answer="B", note="see url")
            )
        ]
    )

    result = await verifier.verify("Q?", "A")

    assert result.verdict == "fact_error"
    assert result.confidence == 0.0
    assert result.alternative_answers == ["B"]


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "responses",
    [
        [TimeoutError("openai timed out")],
        [_openai_response(_verdict_json("ok"), status="incomplete")],
        [_openai_response(None)],
        [_openai_response("no verdict json in this reply")],
    ],
    ids=["api_error", "truncated_incomplete", "empty_output", "prose_no_json"],
)
async def test_openai_failures_hold_instead_of_dropping(responses) -> None:
    """Fail-closed parity with the Anthropic path — incl. a response
    truncated at max_output_tokens (status != completed), which must never
    be read as a verdict."""
    verifier, _ = _openai_verifier(responses)

    result = await verifier.verify("Q?", "A")

    assert result.held_for_review is True
    assert result.verdict == "unverified"


@pytest.mark.asyncio
async def test_openai_cost_covers_tokens_and_web_searches() -> None:
    """gpt-5-mini list price $0.25/1M input; searches at $10/1k = 1¢ each."""
    verifier, _ = _openai_verifier(
        [
            _openai_response(
                _verdict_json("ok"),
                n_searches=3,
                input_tokens=1_000_000,
                output_tokens=0,
            )
        ]
    )

    result = await verifier.verify("Q?", "A")

    # 1M input tokens at $0.25/1M = 25¢, plus 3 searches at 1¢.
    assert result.cost_cents == pytest.approx(28.0)


def test_default_model_routes_to_openai_and_claude_routes_back() -> None:
    """The role default is the OpenAI path; a claude id is the rollback."""
    assert FactVerifier(model="gpt-5-mini")._is_anthropic() is False
    assert FactVerifier(model="claude-sonnet-5")._is_anthropic() is True


# --- _parse_verdict_json ---------------------------------------------------


def test_parse_verdict_json_handles_fences_and_absence() -> None:
    assert _parse_verdict_json('```json\n{"verdict": "ok"}\n```')["verdict"] == "ok"
    assert _parse_verdict_json("no json here") is None
    assert _parse_verdict_json('broken {"verdict": ') is None


# --- session transport (#169) ----------------------------------------------
#
# The Claude Code subscription is a third *transport*, not a third pipeline:
# the founder constraint is that the backend pipeline stays the source of
# truth and the session path mirrors it 1:1. These tests pin exactly that —
# same prompt in, same numeric contract out, same fail-closed behaviour —
# plus the two things unique to the transport: it must be reachable with no
# provider API key at all, and it must never be billed as API cost.


class _FakeSessionChat:
    """``ChatClaudeSession`` double: records prompts, returns canned replies."""

    def __init__(self, replies: list[Any]) -> None:
        self._replies = list(replies)
        self.prompts: list[str] = []

    async def ainvoke(self, prompt: Any, **_: Any) -> Any:
        self.prompts.append(prompt)
        item = self._replies.pop(0)
        if isinstance(item, Exception):
            raise item
        return SimpleNamespace(content=item)


def _session_verifier(
    monkeypatch, model: str, replies: list[Any]
) -> tuple[FactVerifier, _FakeSessionChat, list[dict[str, Any]]]:
    """FactVerifier whose session branch builds the stub via the factory."""
    from quiz_shared.llm import factory as llm_factory

    chat = _FakeSessionChat(replies)
    calls: list[dict[str, Any]] = []

    def _fake_chat_openai(model_id: str, **kwargs: Any) -> Any:
        calls.append({"model": model_id, **kwargs})
        return chat

    monkeypatch.setattr(llm_factory, "chat_openai", _fake_chat_openai)
    return FactVerifier(model=model), chat, calls


@pytest.mark.asyncio
async def test_session_gateway_routes_factcheck_without_any_api_key(
    monkeypatch,
) -> None:
    """LLM_GATEWAY=session must reach the subscription with no provider key
    present: the whole point is a dev run that cannot bill the API. Reading
    the raw role id instead of the gateway-resolved one would send this to
    OpenAI and hold every question on the missing-key preflight."""
    monkeypatch.setenv("LLM_GATEWAY", "session")
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    verifier, chat, calls = _session_verifier(
        monkeypatch, "gpt-5-mini", ["Checked.\n" + _verdict_json("ok")]
    )

    result = await verifier.verify("Q?", "A", topic="film")

    assert result.verdict == "ok"
    assert result.confidence == pytest.approx(0.9)
    assert result.held_for_review is False
    # gpt-5-mini is the web-grounded FACTCHECK role → sonnet tier, and the
    # web tools + agentic turn budget are what make it a fact-*check*.
    assert calls == [{"model": "session:sonnet", "web": True, "max_turns": 8}]
    # Same adversarial prompt as the API branches — transport-only swap.
    assert "Q?" in chat.prompts[0] and "adversarial fact-checker" in chat.prompts[0]


@pytest.mark.asyncio
async def test_session_role_override_routes_without_gateway_flip(monkeypatch) -> None:
    """LLM_ROLE_FACTCHECK=session:haiku must route on the id alone, so one
    role can be moved to the subscription while the rest of the pipeline
    stays on the paid API (the per-role lever documented in #169)."""
    monkeypatch.delenv("LLM_GATEWAY", raising=False)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    verifier, _, calls = _session_verifier(
        monkeypatch, "session:haiku", [_verdict_json("stale", note="superseded")]
    )

    result = await verifier.verify("Q?", "A")

    assert calls[0]["model"] == "session:haiku"
    assert result.verdict == "stale"
    assert result.confidence == 0.0  # below the gate → dropped, same contract


@pytest.mark.asyncio
async def test_session_verdicts_are_free(monkeypatch) -> None:
    """The subscription is a flat fee, so a session verdict must add 0¢ to
    the order total — any non-zero here would inflate pack COGS with money
    that was never spent (tokens are reported via the factory usage proxy)."""
    monkeypatch.setenv("LLM_GATEWAY", "session")
    verifier, _, _ = _session_verifier(monkeypatch, "gpt-5-mini", [_verdict_json("ok")])

    result = await verifier.verify("Q?", "A")

    assert result.cost_cents == 0.0


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "replies",
    [
        [RuntimeError("claude -p exited 1: not logged in")],
        [TimeoutError("claude -p (sonnet) exceeded 300s")],
        [""],
        ["I could not reach a conclusion, sorry."],
    ],
    ids=["cli_error", "timeout", "empty_reply", "prose_no_json"],
)
async def test_session_failures_hold_instead_of_dropping(monkeypatch, replies) -> None:
    """Fail-closed parity with both API branches: a missing CLI, a logged-out
    subscription or a timeout is not evidence about the answer, so the
    question is withheld — never dropped, never kept unchecked (#158)."""
    monkeypatch.setenv("LLM_GATEWAY", "session")
    verifier, _, _ = _session_verifier(monkeypatch, "gpt-5-mini", replies)

    result = await verifier.verify("Q?", "A")

    assert result.held_for_review is True
    assert result.verdict == "unverified"
    assert result.confidence == 0.0
    assert result.cost_cents == 0.0
