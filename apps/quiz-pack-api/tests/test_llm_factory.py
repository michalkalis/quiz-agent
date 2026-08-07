"""Unit tests for the central LLM client factory (issue #53).

These encode the contract the rest of the migration depends on:
- ``direct`` is the default and is byte-for-byte today's behavior (canonical
  endpoint, identity model ids) — so introducing the factory changes nothing.
- ``openrouter`` flips base_url + key + model slugs in one place.
- audio/image (``direct=True``) MUST stay on canonical OpenAI even when the
  gateway is OpenRouter, because Phase 0 proved OpenRouter can't serve them.
"""

import pytest

from quiz_shared.llm import factory


@pytest.fixture(autouse=True)
def _clear_gateway(monkeypatch):
    """Each test sets LLM_GATEWAY explicitly; start from unset (=> direct)."""
    monkeypatch.delenv("LLM_GATEWAY", raising=False)
    monkeypatch.setenv("OPENAI_API_KEY", "sk-openai-test")
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-test")


def test_gateway_defaults_to_direct(monkeypatch):
    assert factory.gateway() == "direct"


def test_gateway_invalid_value_fails_loud(monkeypatch):
    monkeypatch.setenv("LLM_GATEWAY", "litellm")
    with pytest.raises(ValueError, match="LLM_GATEWAY"):
        factory.gateway()


def test_resolve_model_is_identity_in_direct(monkeypatch):
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    assert factory.resolve_model("gpt-4o") == "gpt-4o"
    assert factory.resolve_model("claude-sonnet-4-6") == "claude-sonnet-4-6"
    # #72 Lever A default — identity in direct so the override stays dormant.
    assert factory.resolve_model("claude-opus-4-8") == "claude-opus-4-8"


def test_resolve_model_remaps_in_openrouter(monkeypatch):
    monkeypatch.setenv("LLM_GATEWAY", "openrouter")
    assert factory.resolve_model("gpt-4o") == "openai/gpt-4o"
    assert factory.resolve_model("gpt-4o-mini") == "openai/gpt-4o-mini"
    assert factory.resolve_model("gpt-4.1-mini") == "openai/gpt-4.1-mini"
    assert factory.resolve_model("claude-sonnet-4-6") == "anthropic/claude-sonnet-4.6"
    # #72 Lever A creative-generation default routes through Anthropic on OpenRouter.
    assert factory.resolve_model("claude-opus-4-8") == "anthropic/claude-opus-4.8"
    # The other two #72 Phase-6 A/B candidates (founder-chosen 2026-06-26).
    assert (
        factory.resolve_model("gemini-3.1-pro-preview")
        == "google/gemini-3.1-pro-preview"
    )
    assert factory.resolve_model("kimi-k2.6") == "moonshotai/kimi-k2.6"
    assert factory.resolve_model("gemini-2.5-flash") == "google/gemini-2.5-flash"
    # embeddings keep the same id on OpenRouter
    assert factory.resolve_model("text-embedding-3-small") == "text-embedding-3-small"


def test_resolve_model_passes_unknown_through_in_openrouter(monkeypatch):
    monkeypatch.setenv("LLM_GATEWAY", "openrouter")
    assert factory.resolve_model("some/custom-model") == "some/custom-model"


def test_role_constants_are_frontier_only():
    """2026-07-30 founder policy: the generation pipeline always runs on the
    best available frontier models — a mini/flash-class id reappearing in a
    generation-pipeline role is a regression, not a tweak. Deliberate
    exceptions: EVAL (serve-time hot path, own cost model) and the #135
    founder carve-outs of 2026-08-03 — VERIFY (cheaper evidence arbiter, D9)
    and ANSWERABILITY (cheap round-trip checker is the point, D10)."""
    assert factory.GEN == "claude-fable-5"
    assert factory.CRITIQUE == "gpt-5.6-sol"
    assert factory.EVAL == "gpt-4o-mini"  # serve-time, decided separately
    assert factory.PARSE == "gpt-5.6-sol"
    assert factory.TRANSLATE == "claude-opus-5"
    # #135 D9 carve-out: cheap-frontier arbiter, family-disjoint from every
    # blind-test generation candidate.
    assert factory.VERIFY == "deepseek-v4-pro"
    assert factory.NORMALIZE == "gemini-3.1-pro-preview"
    assert factory.SCORE_OPENAI == "gpt-5.6-sol"
    # Google, not Anthropic: the generator is a Claude model, and a same-family
    # judge is the documented self-preference bias (review 2026-07-30, C).
    assert factory.SCORE_GOOGLE == "gemini-3.1-pro-preview"
    # #135 D7: third judge family = cheap Chinese frontier, disjoint from the
    # GLM/Kimi blind-test generation candidates.
    assert factory.SCORE_THIRD == "deepseek-v4-pro"
    assert factory.ANSWERABILITY == "deepseek-v4-flash"
    assert factory.EMBED == "text-embedding-3-small"

    banned = ("-mini", "-nano", "-flash", "-lite")
    for role_name in ("GEN", "CRITIQUE", "PARSE", "TRANSLATE",
                      "NORMALIZE", "SCORE_OPENAI", "SCORE_GOOGLE",
                      "SCORE_THIRD"):
        model_id = getattr(factory, role_name)
        assert not any(b in model_id for b in banned), (
            f"{role_name}={model_id!r} is a mini/flash-class model — banned "
            "in the generation pipeline (founder policy 2026-07-30; #135 "
            "carve-outs cover only VERIFY and ANSWERABILITY)"
        )


def test_frontier_stack_resolves_on_openrouter(monkeypatch):
    """Every 2026-07-30 role id must have a live-verified OpenRouter slug —
    an unmapped id would pass through raw and 404 at the gateway."""
    monkeypatch.setenv("LLM_GATEWAY", "openrouter")
    assert factory.resolve_model("claude-fable-5") == "anthropic/claude-fable-5"
    assert factory.resolve_model("gpt-5.6-sol") == "openai/gpt-5.6-sol"
    assert factory.resolve_model("claude-opus-5") == "anthropic/claude-opus-5"
    assert (
        factory.resolve_model("gemini-3.1-pro-preview")
        == "google/gemini-3.1-pro-preview"
    )
    # #135 (2026-08-03) — new roles + blind-test candidates, slugs verified
    # live against the OpenRouter catalog the same day.
    assert factory.resolve_model("deepseek-v4-pro") == "deepseek/deepseek-v4-pro"
    assert factory.resolve_model("deepseek-v4-flash") == "deepseek/deepseek-v4-flash"
    assert factory.resolve_model("glm-5.1") == "z-ai/glm-5.1"
    assert factory.resolve_model("kimi-k3") == "moonshotai/kimi-k3"


def test_bedrock_ids_bypass_remap_and_report_provider(monkeypatch):
    """``bedrock:`` ids identify provider+model in one verbatim string: no
    remap table to go stale, and provenance still records the model owner."""
    monkeypatch.setenv("LLM_GATEWAY", "openrouter")
    bedrock_id = "bedrock:anthropic.claude-fable-5-v1:0"
    assert factory.is_bedrock_model(bedrock_id)
    assert factory.resolve_model(bedrock_id) == bedrock_id
    assert factory.provider_for_model(bedrock_id) == "anthropic"


def test_bedrock_without_credentials_fails_loud(monkeypatch):
    """A Bedrock-configured environment without AWS credentials is a config
    error — construction must raise, never silently fall back to another
    provider (a paid order generating on the wrong model is worse than a
    crash)."""
    for var in ("AWS_ACCESS_KEY_ID", "AWS_PROFILE", "AWS_ROLE_ARN",
                "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"):
        monkeypatch.delenv(var, raising=False)
    with pytest.raises(RuntimeError, match="AWS credentials"):
        factory.chat_openai("bedrock:anthropic.claude-fable-5-v1:0")


def test_sampling_params_dropped_for_frontier_families():
    """Claude 5-class and the gpt-5 reasoning family reject temperature with a
    400 (verified on the translator, 2026-07-30); the factory must strip it so
    historical call-site signatures keep working."""
    assert not factory.supports_sampling_params("claude-fable-5")
    assert not factory.supports_sampling_params("claude-opus-5")
    assert not factory.supports_sampling_params("gpt-5.6-sol")
    assert not factory.supports_sampling_params(
        "bedrock:anthropic.claude-fable-5-v1:0"
    )
    assert factory.supports_sampling_params("gpt-4o")
    assert factory.supports_sampling_params("gemini-3.1-pro-preview")


def test_chat_openai_strips_temperature_for_claude_5(monkeypatch):
    """Passing temperature for a Claude 5-class model must not reach the
    client (it would 400 at call time)."""
    monkeypatch.setenv("LLM_GATEWAY", "openrouter")
    llm = factory.chat_openai("claude-fable-5", temperature=0.8)
    assert llm.model_name == "anthropic/claude-fable-5"
    assert getattr(llm, "temperature", None) != 0.8


def test_openai_client_direct_uses_canonical_endpoint(monkeypatch):
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    client = factory.openai_client()
    assert "openrouter.ai" not in str(client.base_url)
    assert client.api_key == "sk-openai-test"


def test_openai_client_openrouter_uses_gateway(monkeypatch):
    monkeypatch.setenv("LLM_GATEWAY", "openrouter")
    client = factory.openai_client()
    assert "openrouter.ai" in str(client.base_url)
    assert client.api_key == "sk-or-test"


def test_direct_flag_pins_canonical_even_when_gateway_is_openrouter(monkeypatch):
    """Audio/image guarantee: TTS/Whisper/image never silently hit OpenRouter."""
    monkeypatch.setenv("LLM_GATEWAY", "openrouter")
    client = factory.openai_client(direct=True)
    assert "openrouter.ai" not in str(client.base_url)
    assert client.api_key == "sk-openai-test"


def test_async_client_type(monkeypatch):
    from openai import AsyncOpenAI, OpenAI

    assert isinstance(factory.openai_client(async_=True), AsyncOpenAI)
    assert isinstance(factory.openai_client(async_=False), OpenAI)


def test_openai_client_defaults_to_bounded_timeout(monkeypatch):
    """The voice hot path must never inherit the SDK's 600s default."""
    client = factory.openai_client()
    assert client.timeout == factory.DEFAULT_TIMEOUT
    assert client.timeout.read == 30.0


def test_openai_client_timeout_is_overridable(monkeypatch):
    """Offline generation call sites pass an explicit longer timeout."""
    client = factory.openai_client(timeout=factory.GENERATION_TIMEOUT)
    assert client.timeout == factory.GENERATION_TIMEOUT
    assert client.timeout.read == 300.0


def test_chat_openai_defaults_to_generation_timeout(monkeypatch):
    """#139: LangChain's own default is an explicit ``timeout=None``, which
    disables httpx timeouts entirely — a stalled generation/critique/scoring
    connection then hangs the worker until ARQ kills the job with zero
    diagnostics (the 2026-08-03 silent order failure)."""
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    llm = factory.chat_openai("gpt-4o")
    assert llm.request_timeout == factory.GENERATION_TIMEOUT
    assert llm.request_timeout.read == 300.0


def test_chat_openai_timeout_stays_overridable(monkeypatch):
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    llm = factory.chat_openai("gpt-4o", timeout=12.5)
    assert llm.request_timeout == 12.5


def test_chat_openai_direct_resolves_model_and_endpoint(monkeypatch):
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    llm = factory.chat_openai("gpt-4o", temperature=0.8)
    assert llm.model_name == "gpt-4o"
    assert llm.temperature == 0.8


def test_chat_openai_openrouter_resolves_slug_and_base_url(monkeypatch):
    monkeypatch.setenv("LLM_GATEWAY", "openrouter")
    llm = factory.chat_openai("gpt-4o-mini")
    assert llm.model_name == "openai/gpt-4o-mini"
    assert "openrouter.ai" in str(llm.openai_api_base)


def test_chat_openai_attaches_usage_handler_when_set(monkeypatch):
    """#153 Phase 0.5 — the registered usage-recording callback must reach
    every client `chat_openai` builds, or per-call token counting silently
    misses whichever call sites forget to check."""
    from langchain_core.callbacks import BaseCallbackHandler

    monkeypatch.setenv("LLM_GATEWAY", "direct")
    handler = BaseCallbackHandler()
    factory.set_usage_handler(handler)
    try:
        llm = factory.chat_openai("gpt-4o")
        assert handler in (llm.callbacks or [])
    finally:
        factory.set_usage_handler(None)


def test_chat_openai_no_callbacks_when_usage_handler_unset(monkeypatch):
    """Zero behavior change for quiz-agent's serve-time path, which never
    registers a usage handler."""
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    assert factory.get_usage_handler() is None
    llm = factory.chat_openai("gpt-4o")
    assert not llm.callbacks
