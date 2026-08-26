"""Central LLM client factory (issue #53 — consolidate providers behind OpenRouter).

One place decides *where* LLM calls go and *which* concrete model serves each
logical role. Call sites ask the factory for a client (and, where the model is
configurable, a resolved model id); they never read an API key or hardcode a
``base_url``. The whole pipeline flips between providers with one env var:

    LLM_GATEWAY=direct      # canonical provider endpoints
    LLM_GATEWAY=openrouter  # everything OpenRouter can serve routes through OpenRouter

Phase 0 of issue #53 proved OpenRouter serves chat + embeddings but **not**
audio (TTS / Whisper) or image (gpt-image-1). Those capabilities pass
``direct=True`` so they stay on canonical OpenAI regardless of the toggle.

Single source of truth for model ids is ``_REMAP_OPENROUTER`` (direct id ->
OpenRouter id). Logical roles below are a convenience layer over direct ids.

**Bedrock (2026-07-30, founder decision):** generation may additionally run on
AWS Bedrock (existing AWS credit) alongside OpenRouter. Any model id of the
form ``bedrock:<bedrock-model-id>`` routes ``chat_model()`` to a
``ChatBedrockConverse`` client with the id passed through verbatim (no remap
table to go stale). Requires ``langchain-aws`` installed and AWS credentials
(``AWS_ACCESS_KEY_ID``/``AWS_SECRET_ACCESS_KEY`` or ambient) — construction
fails loud otherwise; there is no silent fallback to another provider.

**Model policy (founder, 2026-07-30):** the generation pipeline always uses
the best available frontier models — quality over cost. Do not reintroduce
mini/flash-class models into generation, critique, scoring or translation
roles. (Serve-time roles like EVAL have their own cost model and are decided
separately.)

**Founder carve-outs (#135, 2026-08-03):** two verification-side roles are
explicitly exempt from the frontier-only rule — ``VERIFY`` (evidence
arbitration; "Gemini 3.1 Pro is overkill here") and ``ANSWERABILITY`` (the
round-trip answerability check, where a cheap model is the *point*: it proxies
a smart player, not an oracle). Both stay env-overridable via
``app.feature_flags``.
"""

import os
from typing import Any, Optional, Union

import httpx
from openai import AsyncOpenAI, OpenAI

OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"

DIRECT = "direct"
OPENROUTER = "openrouter"

BEDROCK_PREFIX = "bedrock:"

# #153 Phase 0.5 — optional per-call usage callback (quiz-pack-api's
# app.llm_usage), attached to every client `chat_openai` builds when set.
# `None` by default: quiz-agent's serve-time chat calls never register one,
# so this is a zero-behavior-change hook for that app. Typed loosely (not
# `BaseCallbackHandler`) so this module keeps no import-time dependency on
# langchain_core.callbacks beyond what chat_openai already needs lazily.
_usage_handler: Optional[Any] = None


def set_usage_handler(handler: Optional[Any]) -> None:
    """Register (or clear, with `None`) the callback `chat_openai` attaches
    to every client it builds. See `app.llm_usage` module docstring."""
    global _usage_handler
    _usage_handler = handler


def get_usage_handler() -> Optional[Any]:
    return _usage_handler


_usage_proxy: Optional[Any] = None


def _usage_proxy_handler() -> Any:
    """Singleton callback forwarding to the CURRENTLY registered handler.

    Attached to every client unconditionally so registration order cannot
    lose calls: the worker builds its generation/critique clients once at
    startup, long before a per-order recorder registers — a directly
    attached handler would miss them entirely (it silently dropped every
    generation-stage call in the first #153 Phase A run; only lazily built
    clients were counted). The proxy resolves the handler at event time and
    no-ops when nothing is registered.
    """
    global _usage_proxy
    if _usage_proxy is None:
        from langchain_core.callbacks import BaseCallbackHandler

        class _UsageProxy(BaseCallbackHandler):
            def on_llm_end(self, response: Any, **kwargs: Any) -> None:
                handler = _usage_handler
                if handler is not None:
                    handler.on_llm_end(response, **kwargs)

        _usage_proxy = _UsageProxy()
    return _usage_proxy


# Bounds every openai_client() call so the voice-quiz hot path (TTS, Whisper,
# translation, evaluation) never inherits the OpenAI SDK's 600s default.
# ~30s covers that path's latency budget; 5s connect is generous for any
# network path. quiz-pack-api's offline generation pipeline legitimately
# needs longer calls (chat generation, image generation) — those call sites
# pass GENERATION_TIMEOUT explicitly instead of relying on this default.
DEFAULT_TIMEOUT = httpx.Timeout(30.0, connect=5.0)
GENERATION_TIMEOUT = httpx.Timeout(300.0, connect=10.0)


def _role(env_name: str, default: str) -> str:
    """Role model id, overridable via env (founder, 2026-08-06: switching any
    pipeline stage between OpenRouter and Bedrock must be a config change, not
    a code change). Read at import — Fly sets env before process start."""
    return (os.getenv(env_name) or "").strip() or default


# Logical role -> canonical (direct-provider) model id. Frontier-only for the
# generation pipeline (founder policy 2026-07-30, generation-review fix run);
# verified against the live OpenRouter catalog the same day.
GEN = _role("LLM_ROLE_GEN", "claude-fable-5")
CRITIQUE = _role("LLM_ROLE_CRITIQUE", "gpt-5.6-sol")
# EVAL is the serve-time answer grader (voice hot path, per-answer cost model)
# — deliberately NOT part of the 2026-07-30 frontier refresh; revisit
# separately with the founder.
EVAL = "gpt-4o-mini"
PARSE = "gpt-5.6-sol"
TRANSLATE = "claude-opus-5"
NORMALIZE = _role("LLM_ROLE_NORMALIZE", "gemini-3.1-pro-preview")
# #135 D9 (founder carve-out, 2026-08-03): evidence arbitration reads Tavily
# snippets against a claim — frontier-class comprehension at ~7% of the
# gemini-3.1-pro price. Family-disjoint from every blind-test generation
# candidate (Anthropic/OpenAI/Google/GLM/Kimi), so no self-preference either.
# VERIFY_MODEL env (feature_flags.verify_model) switches it back if
# verification quality drops.
VERIFY = "deepseek-v4-pro"
# #166 increment 2 (founder decision 2026-08-24): web-grounded fact-check
# with a native server-side web-search tool — D21b measured 6/6 planted-error
# recall on this pattern vs 0/6 for the Tavily+arbiter verify it replaced.
# Provider research 2026-08-26 (founder-approved swap): gpt-5-mini + the
# OpenAI Responses ``web_search`` tool beat the Sonnet 5 baseline on the
# founder reference (7/7 recall @ ~4 ¢/q vs 5/7 @ ~18 ¢/q, 40q validation).
# A ``claude*`` id routes FactVerifier back to the Anthropic path — rollback
# is ``LLM_ROLE_FACTCHECK=claude-sonnet-5``. Both paths are direct-provider
# carve-outs (no gateway serves either server-side search tool).
FACTCHECK = _role("LLM_ROLE_FACTCHECK", "gpt-5-mini")
SCORE_OPENAI = "gpt-5.6-sol"
# Second judge family. Google, not Anthropic: generation now runs on a Claude
# model, and an Anthropic judge scoring Anthropic output is the documented
# self-preference bias (generation review 2026-07-30, section C).
SCORE_GOOGLE = "gemini-3.1-pro-preview"
# Third judge family for the gate-v2 panel (#135 D7, founder-confirmed
# 2026-08-03: GPT + Gemini + a cheap Chinese frontier). DeepSeek rather than
# GLM/Kimi because those two are 5-model blind-test generation candidates —
# a judge family must stay disjoint from every possible generator.
SCORE_THIRD = "deepseek-v4-pro"
# #135 D10: round-trip answerability checker — a "smart player" proxy, cheap
# by founder approval (2026-08-03). Flash-class is deliberate: if a capable
# cheap model can't reach the answer blind, a player won't either.
ANSWERABILITY = "deepseek-v4-flash"
EMBED = "text-embedding-3-small"

# Direct model id -> OpenRouter slug. Confirmed served via OpenRouter in the
# Phase 0 spike (see docs/issues/issue-53-openrouter-llm-gateway.md). Audio and
# image models are intentionally absent: OpenRouter does not serve them, so
# those call sites use ``direct=True`` and never hit this table.
# ``bedrock:``-prefixed ids never hit this table either (verbatim passthrough).
_REMAP_OPENROUTER = {
    "gpt-4o": "openai/gpt-4o",
    "gpt-4o-mini": "openai/gpt-4o-mini",
    "gpt-4.1": "openai/gpt-4.1",
    "gpt-4.1-mini": "openai/gpt-4.1-mini",
    # 2026-07-30 generation-review refresh — frontier stack. Slugs verified
    # live against the OpenRouter catalog on 2026-07-30.
    "claude-fable-5": "anthropic/claude-fable-5",
    "gpt-5.6-sol": "openai/gpt-5.6-sol",
    "claude-sonnet-4-6": "anthropic/claude-sonnet-4.6",
    # Serve-time question translation (quiz-agent TranslationService, 2026-07-30
    # review); slug verified live against the OpenRouter catalog on 2026-07-30.
    "claude-opus-5": "anthropic/claude-opus-5",
    # Superseded #72 Phase-6 candidates (kept so historical provenance rows and
    # ad-hoc reruns still resolve; the 2026-07-30 founder decision "always the
    # best models" replaced the cheap-tier blind test as the selection route).
    "claude-opus-4-8": "anthropic/claude-opus-4.8",
    "gemini-3.1-pro-preview": "google/gemini-3.1-pro-preview",
    "kimi-k2.6": "moonshotai/kimi-k2.6",
    "glm-5.2": "z-ai/glm-5.2",
    # #135 D1 blind-test candidates + D7/D9/D10 cheap-frontier roles. Slugs
    # verified live against the OpenRouter catalog on 2026-08-03.
    "glm-5.1": "z-ai/glm-5.1",
    "kimi-k3": "moonshotai/kimi-k3",
    "deepseek-v4-pro": "deepseek/deepseek-v4-pro",
    "deepseek-v4-flash": "deepseek/deepseek-v4-flash",
    "gemini-2.5-flash": "google/gemini-2.5-flash",
    "text-embedding-3-small": "text-embedding-3-small",
}

# Friendly aliases for OpenRouter org prefixes that read awkwardly raw.
_PROVIDER_ALIASES = {"moonshotai": "moonshot"}

# Model families that reject OpenAI-style sampling params (temperature/top_p)
# with a 400. Claude 5-class rejects them outright (verified on the translator,
# 2026-07-30: "claude-opus-5 rejects sampling params"); OpenAI's gpt-5
# reasoning family only accepts the default temperature. ``chat_model()``
# silently drops the params for these so call sites can keep passing their
# historical temperatures without per-model branching.
_NO_SAMPLING_PARAMS_PREFIXES = (
    "claude-fable-5",
    "claude-opus-5",
    "claude-sonnet-5",
    "gpt-5",
)


def is_bedrock_model(model_id: str) -> bool:
    """True when ``model_id`` names a Bedrock model (``bedrock:`` prefix)."""
    return model_id.startswith(BEDROCK_PREFIX)


def _strip_bedrock_prefix(model_id: str) -> str:
    return model_id[len(BEDROCK_PREFIX) :] if is_bedrock_model(model_id) else model_id


def supports_sampling_params(model_id: str) -> bool:
    """Whether the model accepts ``temperature``/``top_p`` (see prefix list)."""
    bare = _strip_bedrock_prefix(model_id)
    # Bedrock ids look like "anthropic.claude-fable-5-…" / "us.anthropic.…";
    # match the family anywhere in the id, not just as a prefix.
    return not any(prefix in bare for prefix in _NO_SAMPLING_PARAMS_PREFIXES)


def provider_for_model(model_id: str) -> str:
    """Best-effort model owner/brand for provenance.

    Returns e.g. ``"openai"`` | ``"anthropic"`` | ``"google"`` | ``"moonshot"``.
    The OpenRouter slug prefix in ``_REMAP_OPENROUTER`` is the single source of
    truth; for unmapped/direct/bedrock ids we infer from the id shape. Without
    this the generator hardcodes ``"openai"`` and Gemini/Kimi/Claude rows are
    all mislabelled, defeating the point of recording the model (issue #72 —
    distinguish question sources).
    """
    bare = _strip_bedrock_prefix(model_id)
    slug = _REMAP_OPENROUTER.get(bare, bare)
    if "/" in slug:
        org = slug.split("/", 1)[0]
        return _PROVIDER_ALIASES.get(org, org)
    lowered = bare.lower()
    if "claude" in lowered:
        return "anthropic"
    if "gemini" in lowered:
        return "google"
    if "kimi" in lowered:
        return "moonshot"
    if "nova" in lowered:
        return "amazon"
    if "deepseek" in lowered:
        return "deepseek"
    if "mistral" in lowered or "pixtral" in lowered:
        return "mistral"
    return "openai"


def gateway() -> str:
    """Active gateway, read fresh each call so tests/env flips take effect."""
    value = os.getenv("LLM_GATEWAY", DIRECT).strip().lower()
    if value not in (DIRECT, OPENROUTER):
        raise ValueError(
            f"LLM_GATEWAY must be {DIRECT!r} or {OPENROUTER!r}, got {value!r}"
        )
    return value


def resolve_model(model_id: str) -> str:
    """Translate a direct-provider model id to the active gateway's slug.

    In ``direct`` mode this is the identity. In ``openrouter`` mode known ids
    get their OpenRouter slug; an unknown id passes through unchanged so a
    caller can always force a specific slug. ``bedrock:`` ids are never
    remapped — they identify the provider and exact model in one string.
    """
    if is_bedrock_model(model_id):
        return model_id
    if gateway() == OPENROUTER:
        return _REMAP_OPENROUTER.get(model_id, model_id)
    return model_id


def _base_url_and_key(direct: bool) -> tuple[Optional[str], Optional[str]]:
    """(base_url, api_key) for the OpenAI-compatible client.

    ``direct=True`` forces canonical OpenAI (audio/image, which OpenRouter
    cannot serve). Otherwise the active gateway decides. A ``None`` base_url
    lets the SDK use its default endpoint; a ``None`` key lets the SDK read the
    provider's env var, preserving today's behavior exactly.
    """
    if direct or gateway() == DIRECT:
        return None, os.getenv("OPENAI_API_KEY")
    return OPENROUTER_BASE_URL, os.getenv("OPENROUTER_API_KEY")


def openai_client(
    *,
    async_: bool = False,
    direct: bool = False,
    timeout: Union[httpx.Timeout, float, None] = DEFAULT_TIMEOUT,
) -> Union[OpenAI, AsyncOpenAI]:
    """Native OpenAI-SDK client pointed at the active gateway (or forced direct).

    Use ``direct=True`` for audio (TTS/Whisper) and image generation, which
    OpenRouter does not serve. ``timeout`` defaults to ``DEFAULT_TIMEOUT``
    (~30s) so the voice hot path never inherits the SDK's 600s default; call
    sites that legitimately run long (offline generation) should pass
    ``GENERATION_TIMEOUT`` or another explicit override.
    """
    base_url, api_key = _base_url_and_key(direct)
    cls = AsyncOpenAI if async_ else OpenAI
    return cls(api_key=api_key, base_url=base_url, timeout=timeout)


def anthropic_client(*, timeout: Union[httpx.Timeout, float, None] = None):
    """Native async Anthropic SDK client (#166 increment 2, FACTCHECK role).

    Anthropic's server-side ``web_search`` tool is not served by any
    OpenAI-compatible gateway, so — like audio/image (``direct=True``) —
    this capability stays on the canonical provider regardless of
    ``LLM_GATEWAY``. The SDK reads ``ANTHROPIC_API_KEY`` from the
    environment; call sites never touch the key (contract #53).

    Lazy import: the ``anthropic`` package is a quiz-pack-api dependency
    only — quiz-agent imports this module without it installed. Fails loud
    when missing, mirroring the Bedrock path.
    """
    try:
        from anthropic import AsyncAnthropic
    except ImportError as exc:  # pragma: no cover - exercised via unit test stub
        raise RuntimeError(
            "anthropic_client() requires the 'anthropic' package. Add it to "
            "this app's dependencies (and the Dockerfile pip list, per "
            "memory project_dockerfile_drift)."
        ) from exc

    # GENERATION_TIMEOUT bounds (#139: no unbounded hangs) — a web-grounded
    # fact-check turn runs several server-side searches, so the hot-path
    # DEFAULT_TIMEOUT is too tight.
    return AsyncAnthropic(timeout=timeout if timeout is not None else 300.0)


def _chat_bedrock(model_id: str, **kwargs):
    """LangChain ``ChatBedrockConverse`` for a ``bedrock:`` model id.

    Lazy import: ``langchain-aws`` is only required where Bedrock ids are
    actually configured (quiz-pack-api). Fails loud when the dependency or
    AWS credentials are missing — a Bedrock-configured environment without
    working AWS access is a config error, not a fallback case.
    """
    try:
        from langchain_aws import ChatBedrockConverse
    except ImportError as exc:  # pragma: no cover - exercised via unit test stub
        raise RuntimeError(
            "Model id uses the 'bedrock:' prefix but langchain-aws is not "
            "installed. Add langchain-aws to this app's dependencies (and the "
            "Dockerfile pip list, per memory project_dockerfile_drift)."
        ) from exc

    if not (
        os.getenv("AWS_ACCESS_KEY_ID")
        or os.getenv("AWS_PROFILE")
        or os.getenv("AWS_ROLE_ARN")
        or os.getenv("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")
    ):
        raise RuntimeError(
            "Model id uses the 'bedrock:' prefix but no AWS credentials are "
            "configured (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY). Set them "
            "before selecting a Bedrock model — there is no silent fallback."
        )

    import botocore.config

    region = os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION") or "us-east-1"
    # botocore's 60s read default is too short for pack-generation batches
    # (observed 2026-08-06: kimi-k2.5 Converse ReadTimeoutError killed order
    # 7dbef479). Mirror GENERATION_TIMEOUT's bounds — still finite (#139: no
    # unbounded hangs), just sized for long generation calls.
    bedrock_config = botocore.config.Config(connect_timeout=10, read_timeout=300)
    # Bedrock's per-model default output cap (~8k for kimi-k2.5) silently
    # truncates large generation batches mid-JSON — a 58-question v2_cot
    # batch died at ~34k chars on the default cap and again at ~68k chars on
    # a 16384 cap (order 7dbef479, 2026-08-06). The OpenAI path leaves
    # max_tokens unset and gets the model maximum; mirror that intent with an
    # explicit high bound (all three pipeline models accept 32768, probed
    # live 2026-08-06).
    kwargs.setdefault("max_tokens", 32768)
    return ChatBedrockConverse(
        model=_strip_bedrock_prefix(model_id),
        region_name=region,
        config=bedrock_config,
        **kwargs,
    )


def chat_openai(model: str, **kwargs):
    """LangChain chat model pointed at the active gateway.

    ``model`` is a direct-provider id (remapped to the gateway slug) or a
    ``bedrock:<model-id>`` string (routed to ``ChatBedrockConverse``).
    Sampling params (``temperature``/``top_p``) are dropped for model families
    that reject them (Claude 5-class, gpt-5 reasoning family) so call sites
    keep their historical signatures. Name kept from #53 for call-site
    compatibility even though it can now return a non-OpenAI client.

    #139: when the caller passes no ``timeout``/``request_timeout``, the
    ``ChatOpenAI`` path defaults to ``GENERATION_TIMEOUT``. LangChain's own
    default is an *explicit* ``timeout=None`` handed to the OpenAI SDK, which
    (unlike the omitted-arg sentinel) disables httpx timeouts entirely — a
    stalled connection then hangs the caller forever, which is how a pack
    order died with zero diagnostics on 2026-08-03. The Bedrock path keeps
    boto3's own bounded connect/read defaults.
    """
    if not supports_sampling_params(model):
        kwargs.pop("temperature", None)
        kwargs.pop("top_p", None)

    # #153 Phase 0.5 — always attach the usage proxy so per-call token usage
    # reaches whichever recorder is registered AT CALL TIME (see
    # `_usage_proxy_handler` for why construction-time attachment loses the
    # worker's startup-built clients). No-op at event time when nothing is
    # registered.
    callbacks = list(kwargs.get("callbacks") or [])
    proxy = _usage_proxy_handler()
    if proxy not in callbacks:
        callbacks.append(proxy)
    kwargs["callbacks"] = callbacks

    if is_bedrock_model(model):
        return _chat_bedrock(model, **kwargs)

    from langchain_openai import ChatOpenAI

    if "timeout" not in kwargs and "request_timeout" not in kwargs:
        kwargs["timeout"] = GENERATION_TIMEOUT

    base_url, api_key = _base_url_and_key(direct=False)
    return ChatOpenAI(
        model=resolve_model(model),
        api_key=api_key,
        base_url=base_url,
        **kwargs,
    )


# Explicit alias for new call sites; ``chat_openai`` remains for existing ones.
chat_model = chat_openai


def message_text(message) -> str:
    """Text content of a LangChain chat response.

    ``ChatBedrockConverse`` may return ``content`` as a list of blocks rather
    than a plain string; flatten to the concatenated text parts so call sites
    stay provider-agnostic.
    """
    content = message.content
    if isinstance(content, str):
        return content
    return "".join(
        block.get("text", "") if isinstance(block, dict) else str(block)
        for block in content
    )
