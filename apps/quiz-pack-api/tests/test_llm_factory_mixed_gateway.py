"""``LLM_GATEWAY=mixed``: Claude on the Anthropic credit, the rest via OpenRouter.

Why these matter:
- Offline pack trials should spend the founder's monthly Anthropic API credit
  on Claude calls, while Gemini/OpenAI/DeepSeek models (judges, critique) keep
  OpenRouter: this machine has no direct Google route, so ``direct`` loses the
  Gemini judge (observed 404 -> ``JudgePanelUnavailable``).
- Under plain ``openrouter`` a missing ``ANTHROPIC_API_KEY`` silently sends
  Claude through OpenRouter (credit unused, nobody notices). ``mixed`` states
  the intent, so a missing key must stop the run before any call.
- ``direct`` / ``openrouter`` / ``session`` are what prod and the corpus jobs
  run on; adding ``mixed`` must not change how they resolve.
"""

from __future__ import annotations

import pytest
from app.scoring.multi_model_scorer import MultiModelScorer
from langchain_anthropic import ChatAnthropic
from langchain_openai import ChatOpenAI
from quiz_shared.llm import factory


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("LLM_GATEWAY", "mixed")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-openai-test")
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-test")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")
    monkeypatch.delenv("GOOGLE_API_KEY", raising=False)
    monkeypatch.delenv("JUDGE_MODELS", raising=False)


@pytest.mark.parametrize("model_id", [factory.GEN, factory.GEN_ALT, factory.DEDUP_JUDGE])
def test_claude_ids_go_to_the_anthropic_api(model_id):
    client = factory.chat_model(model_id)

    assert isinstance(client, ChatAnthropic)
    assert client.model == model_id


@pytest.mark.parametrize(
    ("model_id", "slug"),
    [
        (factory.SCORE_GOOGLE, "google/gemini-3.1-pro-preview"),
        (factory.CRITIQUE, "openai/gpt-5.6-sol"),
        (factory.SCORE_THIRD, "deepseek/deepseek-v4-pro"),
    ],
)
def test_other_ids_go_through_openrouter(model_id, slug):
    client = factory.chat_model(model_id)

    assert isinstance(client, ChatOpenAI)
    assert client.model_name == slug
    assert str(client.openai_api_base).startswith(factory.OPENROUTER_BASE_URL)


def test_gemini_judge_joins_the_panel_without_a_google_key():
    # The failure that motivated the route: under ``direct`` the Google judge
    # needs GOOGLE_API_KEY; under ``mixed`` it rides the OpenRouter key.
    providers = {m["provider"] for m in MultiModelScorer._default_models(gate_v2=True)}

    assert providers == {"openai", "google", "deepseek"}


def test_embeddings_follow_openrouter_and_audio_stays_canonical():
    assert str(factory.openai_client().base_url).startswith(factory.OPENROUTER_BASE_URL)
    assert "api.openai.com" in str(factory.openai_client(direct=True).base_url)


def test_provider_labels_stay_the_model_owner():
    # Provenance/cost rows name who made the model, not which pipe carried it.
    assert factory.provider_for_model(factory.GEN) == "anthropic"
    assert factory.provider_for_model(factory.SCORE_GOOGLE) == "google"
    assert factory.provider_for_model(factory.CRITIQUE) == "openai"


@pytest.mark.parametrize("missing", ["ANTHROPIC_API_KEY", "OPENROUTER_API_KEY"])
@pytest.mark.parametrize("model_id", [factory.GEN, factory.SCORE_GOOGLE])
def test_missing_key_fails_loud_instead_of_switching_provider(
    monkeypatch, missing, model_id
):
    monkeypatch.setenv(missing, " ")

    with pytest.raises(RuntimeError, match=missing):
        factory.chat_model(model_id)


@pytest.mark.parametrize("value", ["direct", "openrouter", "session"])
def test_existing_gateways_resolve_as_before(monkeypatch, value):
    monkeypatch.setenv("LLM_GATEWAY", value)

    assert factory.gateway() == value


def test_openrouter_without_anthropic_key_still_falls_back_quietly(monkeypatch):
    # Unchanged #196 rollback lever: only ``mixed`` turns the missing key into
    # an error; plain ``openrouter`` keeps serving Claude via OpenRouter.
    monkeypatch.setenv("LLM_GATEWAY", "openrouter")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "")

    client = factory.chat_model(factory.GEN)

    assert isinstance(client, ChatOpenAI)
    assert client.model_name == "anthropic/claude-opus-5.5"


def test_default_stays_direct(monkeypatch):
    monkeypatch.delenv("LLM_GATEWAY", raising=False)

    assert factory.gateway() == factory.DIRECT
