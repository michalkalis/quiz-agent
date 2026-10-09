"""Claude ids go straight to the Anthropic API (#196 track 196.1).

Why these matter:
- The founder's Max subscription carries an Anthropic API credit; a Claude call
  that still goes through OpenRouter pays a fee from a separate balance, and in
  ``direct`` mode it cannot run at all. So: Claude id + key -> Anthropic.
- No key must mean *exactly* the old route (rollback = unset the secret).
- ``bedrock:`` / ``session:`` ids are explicit provider choices — never hijacked.
- Transport only: same model (OpenRouter dotted slugs map to real dashed ids),
  no sampling params, bounded timeout (#139), usage still recorded and priced.
"""

from __future__ import annotations

import httpx
import pytest
from anthropic.types import Message, TextBlock, ThinkingBlock, Usage
from langchain_anthropic import ChatAnthropic
from langchain_core.outputs import LLMResult
from langchain_openai import ChatOpenAI
from pydantic import BaseModel

from app import llm_usage
from quiz_shared.llm import anthropic_route, factory


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("LLM_GATEWAY", "openrouter")  # prod's gateway
    monkeypatch.setenv("OPENAI_API_KEY", "sk-openai-test")
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-test")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")


@pytest.mark.parametrize(
    ("model_id", "anthropic_id"),
    [
        ("claude-opus-5-5", "claude-opus-5-5"),
        ("claude-fable-5-1", "claude-fable-5-1"),
        ("claude-opus-5", "claude-opus-5"),
        ("claude-sonnet-5", "claude-sonnet-5"),
        ("anthropic/claude-opus-5.5", "claude-opus-5-5"),
        ("anthropic/claude-fable-5.1", "claude-fable-5-1"),
        ("anthropic/claude-sonnet-5.5", "claude-sonnet-5-5"),
        ("anthropic/claude-haiku-5.5", "claude-haiku-5-5"),
    ],
)
def test_claude_id_with_key_routes_to_anthropic_with_real_model_id(model_id, anthropic_id):
    client = factory.chat_model(model_id, temperature=0.7)

    assert isinstance(client, ChatAnthropic)
    assert client.model == anthropic_id
    # Claude 5-class 400s on sampling params — still dropped on this route.
    assert client.temperature is None


def test_unknown_claude_id_passes_through_with_its_sampling_params():
    client = factory.chat_model("claude-sonnet-4-6", temperature=0.7)

    assert isinstance(client, ChatAnthropic)
    assert client.model == "claude-sonnet-4-6"
    assert client.temperature == 0.7  # pre-5 models accept sampling params


def test_anthropic_client_is_bounded_and_records_usage():
    client = factory.chat_model("claude-opus-5-5", timeout=factory.GENERATION_TIMEOUT)

    # #139: never unbounded; the httpx.Timeout collapses to seconds for the SDK.
    assert client.default_request_timeout == factory.GENERATION_TIMEOUT.read
    assert factory._usage_proxy_handler() in client.callbacks
    # No explicit cap -> a generation-sized one, not the library's small default.
    assert client.max_tokens == anthropic_route.DEFAULT_MAX_TOKENS
    assert factory.chat_model("claude-opus-5-5").default_request_timeout == 300.0


@pytest.mark.parametrize("gateway", ["direct", "openrouter"])
def test_no_key_keeps_todays_openai_compatible_route(monkeypatch, gateway):
    monkeypatch.setenv("LLM_GATEWAY", gateway)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "")

    client = factory.chat_model("claude-opus-5-5")

    assert isinstance(client, ChatOpenAI)
    expected = "anthropic/claude-opus-5.5" if gateway == "openrouter" else "claude-opus-5-5"
    assert client.model_name == expected


def test_non_claude_ids_never_route_to_anthropic():
    assert isinstance(factory.chat_model("gpt-5.6-sol"), ChatOpenAI)
    assert isinstance(factory.chat_model("gemini-3.1-pro-preview"), ChatOpenAI)


def test_bedrock_claude_id_keeps_bedrock_route(monkeypatch):
    seen = {}
    monkeypatch.setattr(factory, "_chat_bedrock", lambda m, **kw: seen.setdefault("m", m))

    factory.chat_model("bedrock:us.anthropic.claude-opus-5-5")

    assert seen["m"] == "bedrock:us.anthropic.claude-opus-5-5"


@pytest.mark.parametrize("model_id", ["session:opus", "claude-opus-5-5"])
def test_session_gateway_and_ids_keep_session_route(monkeypatch, model_id):
    monkeypatch.setenv("LLM_GATEWAY", "session")
    seen = {}
    monkeypatch.setattr(factory, "_chat_session", lambda m, **kw: seen.setdefault("m", m))

    factory.chat_model(model_id)

    assert seen["m"] == "session:opus"


class _Out(BaseModel):
    answer: str


def test_structured_output_never_forces_tool_on_models_that_reject_it():
    """Opus 5.5 / Fable 5.1 400 on a forced tool_choice; the generator's MCQ
    path uses with_structured_output, which forces the schema tool by default."""
    bound = factory.chat_model("claude-opus-5-5").with_structured_output(
        _Out, method="function_calling", include_raw=True, tool_choice="auto"
    )
    rendered = repr(bound)
    assert "'tool_choice': {'type': 'auto'}" in rendered

    older = factory.chat_model("claude-opus-5").with_structured_output(_Out)
    assert "'type': 'tool'" in repr(older)  # forced choice still allowed there


def test_usage_of_a_real_anthropic_response_is_recorded_and_priced():
    """The usage proxy must understand ChatAnthropic's llm_output shape, and
    the model id the API echoes back must hit the right price row."""
    client = factory.chat_model("claude-opus-5-5")
    msg = Message(
        id="msg_1",
        type="message",
        role="assistant",
        model="claude-opus-5-5",
        content=[
            ThinkingBlock(type="thinking", thinking="", signature="sig"),
            TextBlock(type="text", text="hello"),
        ],
        stop_reason="end_turn",
        stop_sequence=None,
        usage=Usage(input_tokens=1_000_000, output_tokens=100_000),
    )
    chat_result = client._format_output(msg)
    recorder = llm_usage.UsageRecorder()
    llm_usage.UsageCallbackHandler(recorder).on_llm_end(
        LLMResult(generations=[chat_result.generations], llm_output=chat_result.llm_output)
    )

    entry = recorder.summary()["stages"]["unattributed"]["claude-opus-5-5"]
    assert entry["input_tokens"] == 1_000_000 and entry["output_tokens"] == 100_000
    assert entry["cost_cents"] == pytest.approx(400 + 200)  # $4 in + $20/M * 0.1M
    # Thinking blocks make content a list — call sites read it via message_text.
    assert factory.message_text(chat_result.generations[0].message) == "hello"


@pytest.mark.parametrize(
    ("model", "price"),
    [
        ("claude-fable-5-1", (10.0, 50.0)),
        ("anthropic/claude-fable-5.1", (10.0, 50.0)),
        ("claude-opus-5-5", (4.0, 20.0)),
        ("anthropic/claude-opus-5.5", (4.0, 20.0)),
        ("claude-opus-5", (5.0, 25.0)),
        ("claude-sonnet-5-5", (2.0, 10.0)),
        ("claude-sonnet-5", (2.0, 10.0)),
        ("claude-haiku-5-5", (0.10, 0.50)),
    ],
)
def test_claude_price_rows_match_anthropic_list_prices(model, price):
    """Per-order cost summaries steer model choices; a stale row (Sonnet 5 was
    $3/$15) or a successor falling through to its predecessor's row misleads."""
    row = llm_usage._price_for_model(model)
    assert (row["input"], row["output"]) == price


def test_timeout_seconds_never_returns_unbounded():
    assert anthropic_route.timeout_seconds(None, 30.0) == 30.0
    assert anthropic_route.timeout_seconds(httpx.Timeout(12.0, connect=2.0), 30.0) == 12.0
    assert anthropic_route.timeout_seconds(7, 30.0) == 7.0
