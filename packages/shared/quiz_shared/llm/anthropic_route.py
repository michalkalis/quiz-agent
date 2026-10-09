"""Claude ids straight to the Anthropic API (#196 track 196.1).

Founder 2026-10-09: the Max subscription now carries a monthly Anthropic API
credit, so every chat call whose model is a Claude model should draw on it —
directly, not through OpenRouter (fee + separate balance) or the OpenAI
endpoint (which cannot serve Claude at all in ``direct`` mode).

Rule: a Claude id (``claude-*`` or an OpenRouter ``anthropic/claude-…`` slug)
routes here whenever ``ANTHROPIC_API_KEY`` is set (non-empty) and the gateway
is not ``session``. Explicit ``bedrock:`` / ``session:`` ids keep their own
routes. No key → the caller's previous route, unchanged (fail-safe). Transport
only: the model, the prompts and the sampling-param policy stay identical.

Lazy imports throughout: ``langchain-anthropic`` / ``anthropic`` are only
needed where a Claude id actually routes here.
"""

from __future__ import annotations

import logging
import os
from typing import Any, Union

import httpx

logger = logging.getLogger(__name__)

_OPENROUTER_ORG_PREFIX = "anthropic/"

# Models that answer a forced ``tool_choice`` (``any`` / a named tool) with a
# 400 — claude-api reference, 2026-10-06. LangChain's ``with_structured_output``
# forces the schema tool, so for these we downgrade to ``auto`` (the generator
# already asks for ``auto`` and tells the model in the prompt to use the tool;
# that is exactly what the OpenAI-compatible path sends today).
_NO_FORCED_TOOL_CHOICE_PREFIXES = (
    "claude-fable-5-1",
    "claude-opus-5-5",
    "claude-sonnet-5-5",
    "claude-mythos-5-1",
)

# Mirrors the Bedrock path: the OpenAI-compatible path leaves max_tokens unset
# (= the model maximum); ChatAnthropic would otherwise fall back to a small
# library default and silently truncate large generation batches.
DEFAULT_MAX_TOKENS = 32768

_logged_routes: set[tuple[str, str]] = set()


def is_claude_model(model_id: str) -> bool:
    """True for a bare Claude id or an OpenRouter ``anthropic/claude-…`` slug."""
    lowered = model_id.strip().lower()
    if lowered.startswith(_OPENROUTER_ORG_PREFIX):
        lowered = lowered[len(_OPENROUTER_ORG_PREFIX) :]
    return lowered.startswith("claude-")


def anthropic_model_id(model_id: str) -> str:
    """Real Anthropic API id for a Claude id.

    Strips the OpenRouter org prefix and turns OpenRouter's dotted versions
    into Anthropic's dashed form (``anthropic/claude-opus-5.5`` →
    ``claude-opus-5-5``). Bare dashed ids pass through unchanged, so an
    unknown future id still reaches the API as written.
    """
    bare = model_id.strip()
    if bare.lower().startswith(_OPENROUTER_ORG_PREFIX):
        bare = bare[len(_OPENROUTER_ORG_PREFIX) :]
    return bare.replace(".", "-")


def anthropic_direct_enabled() -> bool:
    """Whether Claude ids may go to the Anthropic API at all right now."""
    from .factory import SESSION, gateway

    return bool((os.getenv("ANTHROPIC_API_KEY") or "").strip()) and gateway() != SESSION


def routes_to_anthropic(model_id: str) -> bool:
    """The routing decision for one model id (see module docstring)."""
    from .factory import is_bedrock_model, is_session_model

    if is_bedrock_model(model_id) or is_session_model(model_id):
        return False
    return is_claude_model(model_id) and anthropic_direct_enabled()


def log_route(model_id: str, route: str) -> None:
    """INFO once per (model, route) so the active route is visible in logs."""
    key = (model_id, route)
    if key not in _logged_routes:
        _logged_routes.add(key)
        logger.info("LLM route: %s -> %s", model_id, route)


def timeout_seconds(
    value: Union[httpx.Timeout, float, int, None], default: float
) -> float:
    """Collapse an httpx.Timeout / number / None to the float seconds the
    Anthropic SDK accepts (#139: never unbounded — None becomes ``default``)."""
    if isinstance(value, httpx.Timeout):
        return float(value.read or default)
    if isinstance(value, (int, float)):
        return float(value)
    return default


_chat_cls: Any = None


def _chat_anthropic_cls() -> Any:
    """ChatAnthropic subclass that never sends a forced tool_choice to a model
    that rejects it (built lazily — langchain-anthropic is an optional dep)."""
    global _chat_cls
    if _chat_cls is None:
        try:
            from langchain_anthropic import ChatAnthropic
        except ImportError as exc:  # pragma: no cover - dependency guard
            raise RuntimeError(
                "Claude id routed to the Anthropic API but langchain-anthropic "
                "is not installed. Add it to this app's dependencies (and the "
                "Dockerfile pip list, per memory project_dockerfile_drift)."
            ) from exc

        class _ChatAnthropicDirect(ChatAnthropic):
            def bind_tools(self, tools, *, tool_choice=None, **kwargs):  # type: ignore[override]
                forced = tool_choice not in (None, "auto", "none") and not (
                    isinstance(tool_choice, dict)
                    and tool_choice.get("type") in ("auto", "none")
                )
                if forced and self.model.startswith(_NO_FORCED_TOOL_CHOICE_PREFIXES):
                    tool_choice = "auto"
                return super().bind_tools(tools, tool_choice=tool_choice, **kwargs)

        _chat_cls = _ChatAnthropicDirect
    return _chat_cls


def chat_anthropic(model_id: str, *, default_timeout: float, **kwargs: Any) -> Any:
    """LangChain chat client on the Anthropic API for a Claude id.

    ``kwargs`` arrive already prepared by ``factory.chat_openai`` (sampling
    params dropped for Claude 5-class, usage proxy attached). Thinking is left
    unset, so the API default applies — the same as the OpenRouter path today.
    """
    raw_timeout = kwargs.pop("timeout", None)
    request_timeout = kwargs.pop("request_timeout", None)
    timeout = timeout_seconds(
        raw_timeout if raw_timeout is not None else request_timeout, default_timeout
    )
    kwargs.setdefault("max_tokens", DEFAULT_MAX_TOKENS)
    model = anthropic_model_id(model_id)
    log_route(model_id, f"anthropic:{model}")
    return _chat_anthropic_cls()(model=model, timeout=timeout, **kwargs)


def message_text(content: Any) -> str:
    """Concatenated text blocks of a native Anthropic SDK response's
    ``content`` (thinking / tool blocks carry no answer text)."""
    return "".join(
        getattr(block, "text", "") or ""
        for block in content
        if getattr(block, "type", None) == "text"
    )
