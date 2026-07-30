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
mini/flash-class models into generation, critique, scoring, verification or
translation roles. (Serve-time roles like EVAL have their own cost model and
are decided separately.)
"""

import os
from typing import Optional, Union

import httpx
from openai import AsyncOpenAI, OpenAI

OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"

DIRECT = "direct"
OPENROUTER = "openrouter"

BEDROCK_PREFIX = "bedrock:"

# Bounds every openai_client() call so the voice-quiz hot path (TTS, Whisper,
# translation, evaluation) never inherits the OpenAI SDK's 600s default.
# ~30s covers that path's latency budget; 5s connect is generous for any
# network path. quiz-pack-api's offline generation pipeline legitimately
# needs longer calls (chat generation, image generation) — those call sites
# pass GENERATION_TIMEOUT explicitly instead of relying on this default.
DEFAULT_TIMEOUT = httpx.Timeout(30.0, connect=5.0)
GENERATION_TIMEOUT = httpx.Timeout(300.0, connect=10.0)

# Logical role -> canonical (direct-provider) model id. Frontier-only for the
# generation pipeline (founder policy 2026-07-30, generation-review fix run);
# verified against the live OpenRouter catalog the same day.
GEN = "claude-fable-5"
CRITIQUE = "gpt-5.6-sol"
# EVAL is the serve-time answer grader (voice hot path, per-answer cost model)
# — deliberately NOT part of the 2026-07-30 frontier refresh; revisit
# separately with the founder.
EVAL = "gpt-4o-mini"
PARSE = "gpt-5.6-sol"
TRANSLATE = "claude-opus-5"
NORMALIZE = "gemini-3.1-pro-preview"
VERIFY = "gemini-3.1-pro-preview"
SCORE_OPENAI = "gpt-5.6-sol"
# Second judge family. Google, not Anthropic: generation now runs on a Claude
# model, and an Anthropic judge scoring Anthropic output is the documented
# self-preference bias (generation review 2026-07-30, section C).
SCORE_GOOGLE = "gemini-3.1-pro-preview"
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

    region = os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION") or "us-east-1"
    return ChatBedrockConverse(
        model=_strip_bedrock_prefix(model_id),
        region_name=region,
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
    """
    if not supports_sampling_params(model):
        kwargs.pop("temperature", None)
        kwargs.pop("top_p", None)

    if is_bedrock_model(model):
        return _chat_bedrock(model, **kwargs)

    from langchain_openai import ChatOpenAI

    base_url, api_key = _base_url_and_key(direct=False)
    return ChatOpenAI(
        model=resolve_model(model),
        api_key=api_key,
        base_url=base_url,
        **kwargs,
    )


# Explicit alias for new call sites; ``chat_openai`` remains for existing ones.
chat_model = chat_openai
