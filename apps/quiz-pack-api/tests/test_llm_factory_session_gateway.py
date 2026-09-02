"""Factory-level tests for #169 ``LLM_GATEWAY=session``.

These lock two things separately: the id -> ``session:<alias>`` resolution
table (the founder-approved mapping from prod model ids to a Claude
subscription tier), and the regression guarantee that the whole feature is
additive — with ``LLM_GATEWAY`` unset, the pre-#169 factory behaviour must be
byte-for-byte unchanged. Companion to ``test_llm_factory.py`` (direct/
openrouter) and ``test_llm_session_cli.py`` (the ``ChatClaudeSession``
transport itself).
"""

import pytest

from quiz_shared.llm import factory
from quiz_shared.llm.session_cli import ChatClaudeSession

from tests._fake_claude_cli import default_response, setup_fake_claude


@pytest.fixture(autouse=True)
def _clear_gateway(monkeypatch):
    monkeypatch.delenv("LLM_GATEWAY", raising=False)
    monkeypatch.delenv("LLM_SESSION_MAP", raising=False)
    monkeypatch.setenv("OPENAI_API_KEY", "sk-openai-test")


def test_gateway_accepts_session_and_still_rejects_garbage(monkeypatch):
    """LLM_GATEWAY=session is a real third mode, not a typo the validator
    should let slip through alongside actual garbage values."""
    monkeypatch.setenv("LLM_GATEWAY", "session")
    assert factory.gateway() == "session"
    monkeypatch.setenv("LLM_GATEWAY", "sesion")
    with pytest.raises(ValueError, match="LLM_GATEWAY"):
        factory.gateway()


@pytest.mark.parametrize(
    "model_id,alias",
    [
        ("claude-fable-5", "fable"),
        ("claude-opus-5", "opus"),
        ("claude-sonnet-5", "sonnet"),
        ("gpt-5-mini", "sonnet"),  # web-grounded FACTCHECK
        ("deepseek-v4-flash", "haiku"),  # deliberately flash-class ANSWERABILITY
        ("gpt-5.6-sol", "opus"),  # frontier-class CRITIQUE/PARSE
        ("gemini-3.1-pro-preview", "opus"),  # frontier-class NORMALIZE/SCORE_GOOGLE
        ("bedrock:moonshotai.kimi-k2.5", "opus"),  # unknown/bedrock default
    ],
)
def test_resolve_model_session_alias_table(monkeypatch, model_id, alias):
    """Founder decision 2026-09-02: every prod chat id must land on a Claude
    tier under the session gateway — an unmapped id silently defaulting to
    the wrong tier would burn cheap-role quota on frontier prompts, or run a
    cheap-role check on an expensive tier for nothing."""
    monkeypatch.setenv("LLM_GATEWAY", "session")
    assert factory.resolve_model(model_id) == f"session:{alias}"


def test_resolve_model_session_leaves_embeddings_unmapped(monkeypatch):
    """Embeddings have no subscription equivalent (founder carve-out) — they
    must keep hitting the OpenAI API even under LLM_GATEWAY=session."""
    monkeypatch.setenv("LLM_GATEWAY", "session")
    assert factory.resolve_model("text-embedding-3-small") == "text-embedding-3-small"


def test_llm_session_map_overrides_default_alias(monkeypatch):
    """LLM_SESSION_MAP is the rollback/tuning lever for a single role (e.g.
    demoting FACTCHECK from sonnet to haiku after validation) without a code
    change."""
    monkeypatch.setenv("LLM_GATEWAY", "session")
    monkeypatch.setenv("LLM_SESSION_MAP", "gpt-5-mini=haiku")
    assert factory.resolve_model("gpt-5-mini") == "session:haiku"


def test_chat_openai_session_returns_session_client_without_sampling_param_error(
    monkeypatch,
):
    """Call sites keep passing their historical temperature/max_tokens kwargs
    unmodified — chat_openai must silently drop the sampling params rather
    than let them reach (and error against) a transport that exposes none."""
    monkeypatch.setenv("LLM_GATEWAY", "session")
    llm = factory.chat_openai("gpt-5-mini", temperature=0.3, max_tokens=100)
    assert isinstance(llm, ChatClaudeSession)
    assert llm.alias == "sonnet"


def test_session_timeout_defaults_to_the_http_generation_belt(monkeypatch):
    """Unset LLM_SESSION_TIMEOUT must leave the pre-existing deadline alone —
    the override is additive, so a session run that does not ask for it keeps
    behaving exactly as it did before this knob existed."""
    monkeypatch.setenv("LLM_GATEWAY", "session")
    monkeypatch.delenv("LLM_SESSION_TIMEOUT", raising=False)
    llm = factory.chat_openai("claude-fable-5", max_tokens=32768)
    assert llm.timeout == factory.GENERATION_TIMEOUT.read


def test_session_timeout_override_wins_over_the_call_sites_http_timeout(monkeypatch):
    """``claude -p`` is a slower transport than the HTTP API the call sites
    sized their timeout for: a #167 fact-first batch measured 412 s on
    session:fable and so could never finish inside the 300 s
    GENERATION_TIMEOUT. The override is what makes a full-size batch
    reachable at all — without it the run dies mid-call every time,
    regardless of fact-pool size."""
    monkeypatch.setenv("LLM_GATEWAY", "session")
    monkeypatch.setenv("LLM_SESSION_TIMEOUT", "1500")
    llm = factory.chat_openai("claude-fable-5", max_tokens=32768)
    assert llm.timeout == 1500.0


def test_base_url_and_key_session_behaves_like_direct(monkeypatch):
    """The OpenAI SDK client under session mode only ever serves embeddings/
    audio/image (no subscription equivalent) — it must hit canonical OpenAI,
    not OpenRouter."""
    monkeypatch.setenv("LLM_GATEWAY", "session")
    assert factory._base_url_and_key(direct=False) == (None, "sk-openai-test")


def test_supports_sampling_params_false_for_session_ids():
    assert factory.supports_sampling_params("session:opus") is False


def test_provider_for_model_session_is_anthropic():
    assert factory.provider_for_model("session:opus") == "anthropic"


def test_usage_handler_receives_session_model_name_and_usage(tmp_path, monkeypatch):
    """#153 usage tracking must see session calls too (model ``session:<alias>``
    logged as unpriced) so subscription-side consumption stays visible even
    though it costs the pipeline $0."""
    setup_fake_claude(
        monkeypatch,
        tmp_path,
        control={
            "response": default_response(usage={"input_tokens": 30, "output_tokens": 6})
        },
    )
    monkeypatch.setenv("LLM_GATEWAY", "session")

    seen = []

    class _Recorder:
        def on_llm_end(self, response, **kwargs):
            seen.append(response.llm_output)

    factory.set_usage_handler(_Recorder())
    try:
        factory.chat_openai("claude-opus-5").invoke("hi")
    finally:
        factory.set_usage_handler(None)

    assert seen, "usage handler was never invoked"
    assert seen[0]["model_name"] == "session:opus"
    assert seen[0]["usage"]["input_tokens"] == 30
    assert seen[0]["usage"]["output_tokens"] == 6


# --- Regression guard: LLM_GATEWAY unset must stay exactly the pre-#169 path


_PROD_IDS = [
    "gpt-4o",
    "gpt-4o-mini",
    "gpt-4.1",
    "gpt-4.1-mini",
    "claude-fable-5",
    "gpt-5.6-sol",
    "claude-sonnet-4-6",
    "claude-opus-5",
    "claude-opus-4-8",
    "gemini-3.1-pro-preview",
    "kimi-k2.6",
    "glm-5.2",
    "gpt-5-mini",
    "deepseek-v4-flash",
    "deepseek-v4-pro",
    "text-embedding-3-small",
    "bedrock:anthropic.claude-fable-5-v1:0",
]


def test_resolve_model_untouched_without_gateway_set():
    """#169 is additive: with LLM_GATEWAY unset, resolve_model must still be
    the identity function it was before this feature existed."""
    assert factory.resolve_model("gpt-5-mini") == "gpt-5-mini"


@pytest.mark.parametrize("model_id", _PROD_IDS)
def test_is_session_model_false_for_every_prod_id(model_id):
    """A prod id must never be mistaken for a session: id outside session
    mode — that would misroute a live call onto the subprocess transport."""
    assert factory.is_session_model(model_id) is False
