"""Unit tests for #153 Phase 0.5 — per-stage, per-model LLM token/cost
accounting (`app.llm_usage`).

Why each scenario:
- Two providers report usage in different shapes (ChatOpenAI's
  `llm_output["token_usage"]` vs ChatBedrockConverse's per-message
  `usage_metadata`, which sets no `llm_output` at all) — both must land in
  the same counters or one provider's spend silently vanishes.
- A call with neither shape must still increment `calls` (via
  `calls_without_usage`) — a provider that stops reporting usage is a data
  gap the summary must show, not a quietly-shrinking total.
- Attribution rides the `current_stage` contextvar, not any LangChain
  run-tree metadata, so the two-stage test pins that the SAME model's calls
  land in different stage buckets when the contextvar changes between calls.
- Price math and the unpriced-model list are what `#143`'s cost decisions
  will read, so both get a pinned unit test.
"""

from __future__ import annotations

from app import llm_usage
from langchain_core.messages import AIMessage
from langchain_core.outputs import ChatGeneration, LLMResult


def _openai_style_response(model: str, prompt_tokens: int, completion_tokens: int) -> LLMResult:
    """Mimics ChatOpenAI's `_create_chat_result`: usage lives in `llm_output`."""
    return LLMResult(
        generations=[[ChatGeneration(message=AIMessage(content="hi"))]],
        llm_output={
            "token_usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
            },
            "model_name": model,
        },
    )


def _bedrock_style_response(model: str, input_tokens: int, output_tokens: int) -> LLMResult:
    """Mimics ChatBedrockConverse: no `llm_output`, usage on the message."""
    message = AIMessage(
        content="hi",
        response_metadata={"model_provider": "bedrock_converse", "model_name": model},
        usage_metadata={
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "total_tokens": input_tokens + output_tokens,
        },
    )
    return LLMResult(generations=[[ChatGeneration(message=message)]], llm_output=None)


def _no_usage_response(model: str) -> LLMResult:
    """A provider response that carries a model name but no usage at all."""
    message = AIMessage(content="hi", response_metadata={"model_name": model})
    return LLMResult(generations=[[ChatGeneration(message=message)]], llm_output=None)


def test_callback_accumulates_openai_style_usage() -> None:
    recorder = llm_usage.UsageRecorder()
    handler = llm_usage.UsageCallbackHandler(recorder)
    token = llm_usage.current_stage.set("generation")
    try:
        handler.on_llm_end(_openai_style_response("gpt-4o", 100, 50))
    finally:
        llm_usage.current_stage.reset(token)

    bucket = recorder.summary()["stages"]["generation"]["gpt-4o"]
    assert bucket["calls"] == 1
    assert bucket["input_tokens"] == 100
    assert bucket["output_tokens"] == 50
    assert bucket["calls_without_usage"] == 0


def test_callback_accumulates_message_usage_metadata_shape() -> None:
    """ChatBedrockConverse sets no `llm_output` — usage must still be found
    via the per-message `usage_metadata` fallback."""
    recorder = llm_usage.UsageRecorder()
    handler = llm_usage.UsageCallbackHandler(recorder)
    token = llm_usage.current_stage.set("generation")
    try:
        handler.on_llm_end(_bedrock_style_response("moonshotai.kimi-k2.5", 30, 20))
    finally:
        llm_usage.current_stage.reset(token)

    bucket = recorder.summary()["stages"]["generation"]["moonshotai.kimi-k2.5"]
    assert bucket["calls"] == 1
    assert bucket["input_tokens"] == 30
    assert bucket["output_tokens"] == 20
    assert bucket["calls_without_usage"] == 0


def test_missing_usage_is_counted_loudly_not_silently() -> None:
    recorder = llm_usage.UsageRecorder()
    handler = llm_usage.UsageCallbackHandler(recorder)
    token = llm_usage.current_stage.set("verification")
    try:
        handler.on_llm_end(_no_usage_response("gpt-4o"))
    finally:
        llm_usage.current_stage.reset(token)

    bucket = recorder.summary()["stages"]["verification"]["gpt-4o"]
    assert bucket["calls"] == 1
    assert bucket["calls_without_usage"] == 1
    assert bucket["input_tokens"] == 0
    assert bucket["output_tokens"] == 0


def test_contextvar_attributes_same_model_to_different_stages() -> None:
    recorder = llm_usage.UsageRecorder()
    handler = llm_usage.UsageCallbackHandler(recorder)

    token = llm_usage.current_stage.set("generation")
    try:
        handler.on_llm_end(_openai_style_response("gpt-4o", 10, 5))
    finally:
        llm_usage.current_stage.reset(token)

    token = llm_usage.current_stage.set("verification")
    try:
        handler.on_llm_end(_openai_style_response("gpt-4o", 40, 20))
    finally:
        llm_usage.current_stage.reset(token)

    stages = recorder.summary()["stages"]
    assert stages["generation"]["gpt-4o"]["input_tokens"] == 10
    assert stages["verification"]["gpt-4o"]["input_tokens"] == 40
    # The stages are independent counters even though the model is identical.
    assert stages["generation"]["gpt-4o"]["calls"] == 1
    assert stages["verification"]["gpt-4o"]["calls"] == 1


def test_current_stage_defaults_to_unattributed() -> None:
    assert llm_usage.current_stage.get() == "unattributed"


def test_price_math_for_a_known_model() -> None:
    recorder = llm_usage.UsageRecorder()
    recorder.record("generation", "gpt-4o-mini", 1_000_000, 1_000_000)

    bucket = recorder.summary()["stages"]["generation"]["gpt-4o-mini"]
    # $0.15/1M input + $0.60/1M output = $0.75 -> 75.0 cents.
    assert bucket["cost_cents"] == 75.0
    assert "gpt-4o-mini" not in recorder.summary()["unpriced_models"]


def test_unknown_model_lands_in_unpriced_models() -> None:
    recorder = llm_usage.UsageRecorder()
    recorder.record("generation", "some-future-model-xyz", 100, 100)

    summary = recorder.summary()
    assert summary["unpriced_models"] == ["some-future-model-xyz"]
    assert summary["stages"]["generation"]["some-future-model-xyz"]["cost_cents"] is None
    # Cost from the unpriced model must not sneak into the known total.
    assert summary["total_cost_cents_known"] == 0.0
