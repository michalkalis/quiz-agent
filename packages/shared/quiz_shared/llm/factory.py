"""Central LLM client factory (issue #53 — consolidate providers behind OpenRouter).

One place decides *where* LLM calls go and *which* concrete model serves each
logical role. Call sites ask the factory for a client (and, where the model is
configurable, a resolved model id); they never read an API key or hardcode a
``base_url``. The whole pipeline flips between providers with one env var:

    LLM_GATEWAY=direct      # default — canonical provider endpoints (today's behavior)
    LLM_GATEWAY=openrouter  # everything OpenRouter can serve routes through OpenRouter

Phase 0 of issue #53 proved OpenRouter serves chat + embeddings but **not**
audio (TTS / Whisper) or image (gpt-image-1). Those capabilities pass
``direct=True`` so they stay on canonical OpenAI regardless of the toggle.

Single source of truth for model ids is ``_REMAP_OPENROUTER`` (direct id ->
OpenRouter id). Logical roles below are a convenience layer over direct ids.
"""

import os
from typing import Optional, Union

from openai import AsyncOpenAI, OpenAI

OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"

DIRECT = "direct"
OPENROUTER = "openrouter"

# Logical role -> canonical (direct-provider) model id. These mirror the
# defaults that live at each call site today; keeping them here lets the
# gateway switch and any future model bump happen in one place.
GEN = "gpt-4o"
CRITIQUE = "gpt-4o-mini"
EVAL = "gpt-4o-mini"
PARSE = "gpt-4o-mini"
TRANSLATE = "gpt-4o-mini"
NORMALIZE = "gemini-2.5-flash"
VERIFY = "gemini-2.5-flash"
SCORE_OPENAI = "gpt-4.1-mini"
SCORE_ANTHROPIC = "claude-sonnet-4-6"
EMBED = "text-embedding-3-small"

# Direct model id -> OpenRouter slug. Confirmed served via OpenRouter in the
# Phase 0 spike (see docs/issues/issue-53-openrouter-llm-gateway.md). Audio and
# image models are intentionally absent: OpenRouter does not serve them, so
# those call sites use ``direct=True`` and never hit this table.
_REMAP_OPENROUTER = {
    "gpt-4o": "openai/gpt-4o",
    "gpt-4o-mini": "openai/gpt-4o-mini",
    "gpt-4.1": "openai/gpt-4.1",
    "gpt-4.1-mini": "openai/gpt-4.1-mini",
    "claude-sonnet-4-6": "anthropic/claude-sonnet-4.6",
    # Creative-generation default for issue #72 (Lever A), dormant until the
    # GENERATION_MODEL flag is flipped at Phase 6. Slug follows the established
    # Anthropic convention (dashes in the direct id -> dot in the OpenRouter
    # slug, cf. claude-sonnet-4-6); verify against the live catalog before the
    # Phase-6 flip per the issue's verify-live note.
    "claude-opus-4-8": "anthropic/claude-opus-4.8",
    # The other two #72 Phase-6 A/B candidates (founder-chosen 2026-06-26),
    # likewise dormant until GENERATION_MODEL selects one. Slugs verified live
    # against the OpenRouter catalog on 2026-06-26.
    "gemini-3.1-pro-preview": "google/gemini-3.1-pro-preview",
    "kimi-k2.6": "moonshotai/kimi-k2.6",
    "gemini-2.5-flash": "google/gemini-2.5-flash",
    "text-embedding-3-small": "text-embedding-3-small",
}

# Friendly aliases for OpenRouter org prefixes that read awkwardly raw.
_PROVIDER_ALIASES = {"moonshotai": "moonshot"}


def provider_for_model(model_id: str) -> str:
    """Best-effort model owner/brand for provenance.

    Returns e.g. ``"openai"`` | ``"anthropic"`` | ``"google"`` | ``"moonshot"``.
    The OpenRouter slug prefix in ``_REMAP_OPENROUTER`` is the single source of
    truth; for unmapped/direct ids we infer from the id shape. Without this the
    generator hardcodes ``"openai"`` and Gemini/Kimi/Claude rows are all
    mislabelled, defeating the point of recording the model (issue #72 —
    distinguish question sources).
    """
    slug = _REMAP_OPENROUTER.get(model_id, model_id)
    if "/" in slug:
        org = slug.split("/", 1)[0]
        return _PROVIDER_ALIASES.get(org, org)
    lowered = model_id.lower()
    if lowered.startswith("claude"):
        return "anthropic"
    if lowered.startswith("gemini"):
        return "google"
    if lowered.startswith("kimi"):
        return "moonshot"
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
    caller can always force a specific slug.
    """
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
    *, async_: bool = False, direct: bool = False
) -> Union[OpenAI, AsyncOpenAI]:
    """Native OpenAI-SDK client pointed at the active gateway (or forced direct).

    Use ``direct=True`` for audio (TTS/Whisper) and image generation, which
    OpenRouter does not serve.
    """
    base_url, api_key = _base_url_and_key(direct)
    cls = AsyncOpenAI if async_ else OpenAI
    return cls(api_key=api_key, base_url=base_url)


def chat_openai(model: str, **kwargs):
    """LangChain ``ChatOpenAI`` pointed at the active gateway.

    ``model`` is a direct-provider id; it is remapped to the gateway slug. Extra
    kwargs (e.g. ``temperature``) pass straight through.
    """
    from langchain_openai import ChatOpenAI

    base_url, api_key = _base_url_and_key(direct=False)
    return ChatOpenAI(
        model=resolve_model(model),
        api_key=api_key,
        base_url=base_url,
        **kwargs,
    )
