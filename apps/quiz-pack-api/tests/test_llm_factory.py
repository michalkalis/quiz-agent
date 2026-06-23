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
    assert factory.resolve_model("gemini-2.5-flash") == "google/gemini-2.5-flash"
    # embeddings keep the same id on OpenRouter
    assert factory.resolve_model("text-embedding-3-small") == "text-embedding-3-small"


def test_resolve_model_passes_unknown_through_in_openrouter(monkeypatch):
    monkeypatch.setenv("LLM_GATEWAY", "openrouter")
    assert factory.resolve_model("some/custom-model") == "some/custom-model"


def test_role_constants_match_call_site_defaults():
    # Guard against silent drift from the models the pipeline runs today.
    assert factory.GEN == "gpt-4o"
    assert factory.CRITIQUE == "gpt-4o-mini"
    assert factory.EVAL == "gpt-4o-mini"
    assert factory.PARSE == "gpt-4o-mini"
    assert factory.TRANSLATE == "gpt-4o-mini"
    assert factory.VERIFY == "gemini-2.5-flash"
    assert factory.NORMALIZE == "gemini-2.5-flash"
    assert factory.SCORE_OPENAI == "gpt-4.1-mini"
    assert factory.SCORE_ANTHROPIC == "claude-sonnet-4-6"
    assert factory.EMBED == "text-embedding-3-small"


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
