"""Bounded LLM calls on the live answer path (#193 — beta hardening, task 193.11).

A spoken answer can need two sequential LLM calls: the intent classifier
(``InputParser``) and the judge (``AnswerEvaluator``). With the shared
factory's defaults each call could take 30 s per attempt × 3 attempts, so a
slow or down provider (OpenRouter or direct OpenAI — both go through the same
OpenAI SDK client) held the player for 30–90 s and then answered 500, long
after the app's 30 s budget (``withUserFacingTimeout`` in iOS) had given up.

This module only changes what happens when the provider fails. A call that
succeeds sends the identical request and gets the identical verdict — the
request kwargs pass through untouched.

Budget (iOS gives the whole submit 30 s, which also has to cover upload,
transcription and the feedback TTS):

- ``ATTEMPT_TIMEOUT`` 8 s read / 2 s connect per attempt. Measured on
  gpt-4o-mini (2026-10-08, 30 calls per type per gateway): the classifier runs
  p50 1.5–2 s, p95 2.2–3.2 s, max 7.85 s (direct OpenAI); the judge peaks
  around 2 s. 8 s clears the slowest classifier call seen.
- ``MAX_RETRIES`` 1 (SDK default is 2): one quick retry covers a dropped
  connection or a one-off 5xx/429.
- ``CALL_BUDGET_S`` 12 s hard cap on one call, retries included. The SDK can
  sleep up to 60 s on a ``Retry-After`` header; this cap overrides that.

Normal worst case per answer: slowest classifier (~8 s) + slowest judge
(~2 s) = ~10 s of LLM time, ~15 s with upload, transcription and TTS. During
an outage the first failing call ends the submit, so at most 12 s of LLM time.
Only a classifier that barely succeeds near the cap followed by a failing
judge reaches 24 s; past iOS's 30 s the app shows its own "timed out, try
again", still nothing graded.

#196 (track 196.3, founder 2026-10-10): both roles run on Claude Haiku 5.5 at
effort ``low`` on the direct Anthropic API (eval:
docs/testing/runs/haiku-eval-2026-10-10 — wrong "incorrect" verdicts 9 → 1 of
190, same or better p90). ``EVAL_MODEL`` / ``PARSE_MODEL`` pick the model, so
rollback is one Fly secret (``=gpt-4o-mini``). The Claude call is fail-safe:
no key, an error, a timeout or an unusable reply sends that one call to
``FALLBACK_MODEL`` on the path above, unchanged — so the switch can never cost
a player a verdict. The Claude attempt gets one ``CLAUDE_TIMEOUT_S`` try (no
retry) before falling back: 8 s + the 12 s fallback budget = 20 s, still inside
iOS's 30 s.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from types import SimpleNamespace
from typing import Any

import httpx
import openai
import sentry_sdk
from quiz_shared.llm import anthropic_route
from quiz_shared.llm import factory as llm_factory

from .quiz.errors import JudgeUnavailable

logger = logging.getLogger(__name__)

ATTEMPT_TIMEOUT = httpx.Timeout(8.0, connect=2.0)
MAX_RETRIES = 1
CALL_BUDGET_S = 12.0

# One Sentry event per incident, not one per answer: every player answering
# during an outage hits this, and each would otherwise be its own event.
SENTRY_REPORT_INTERVAL_S = 600.0
_last_reported_at: float | None = None

DEFAULT_MODEL = "claude-haiku-5-5"
FALLBACK_MODEL = "gpt-4o-mini"
# Eval: effort low matched medium on wrong "incorrect" verdicts at a lower p90.
CLAUDE_EFFORT = "low"
# Room for adaptive thinking plus the parser's JSON (~160 tokens at low).
CLAUDE_MAX_TOKENS = 2048
CLAUDE_TIMEOUT_S = 8.0

_anthropic_llm: Any = None
_fallback_warned: set[str] = set()


def role_model(env_name: str) -> str:
    """Model id for an answer-path role: ``env_name`` if set, else Haiku 5.5."""
    return (os.getenv(env_name) or "").strip() or DEFAULT_MODEL


def client() -> openai.AsyncOpenAI:
    """The async OpenAI-SDK client the answer path uses (active gateway)."""
    return llm_factory.openai_client(async_=True, timeout=ATTEMPT_TIMEOUT).with_options(
        max_retries=MAX_RETRIES
    )


async def complete(llm: Any, *, stage: str, **request: Any) -> Any:
    """``llm.chat.completions.create(**request)`` within ``CALL_BUDGET_S``.

    Raises ``JudgeUnavailable`` when the provider errors or does not answer in
    time, so the submit flow can ask the player again instead of failing.

    A Claude ``model`` goes to the Anthropic API first (#196); if that does not
    produce a reply, the same request runs on ``FALLBACK_MODEL`` through
    ``llm`` exactly as before the switch.
    """
    if anthropic_route.is_claude_model(request.get("model") or ""):
        reply = await _complete_claude(stage, request)
        if reply is not None:
            return reply
        request = {**request, "model": llm_factory.resolve_model(FALLBACK_MODEL)}
    try:
        return await asyncio.wait_for(
            llm.chat.completions.create(**request), timeout=CALL_BUDGET_S
        )
    except (TimeoutError, openai.APIError) as exc:
        _report(stage, request.get("model"), exc)
        raise JudgeUnavailable(stage) from exc


def _anthropic() -> Any:
    global _anthropic_llm
    if _anthropic_llm is None:
        _anthropic_llm = llm_factory.anthropic_client(
            timeout=CLAUDE_TIMEOUT_S
        ).with_options(max_retries=0)
    return _anthropic_llm


async def _complete_claude(stage: str, request: dict[str, Any]) -> Any | None:
    """The request on the Anthropic API, shaped like an OpenAI response, or
    ``None`` when the caller must fall back. Haiku 5.5 rejects ``temperature``
    (400), so it is never sent; the prompts go out unchanged."""
    model = request["model"]
    if not anthropic_route.routes_to_anthropic(model):
        _note_fallback(stage, model, "anthropic route unavailable (no key?)")
        return None
    messages = request["messages"]
    try:
        reply = await asyncio.wait_for(
            _anthropic().messages.create(
                model=anthropic_route.anthropic_model_id(model),
                max_tokens=CLAUDE_MAX_TOKENS,
                system="\n".join(
                    m["content"] for m in messages if m["role"] == "system"
                ),
                messages=[m for m in messages if m["role"] != "system"],
                output_config={"effort": CLAUDE_EFFORT},
            ),
            timeout=CLAUDE_TIMEOUT_S,
        )
    except Exception as exc:  # noqa: BLE001 — any failure means: use the fallback
        _note_fallback(stage, model, type(exc).__name__)
        return None
    text = anthropic_route.message_text(reply.content).strip()
    if reply.stop_reason != "end_turn" or not text:
        _note_fallback(stage, model, f"stop_reason={reply.stop_reason}")
        return None
    return SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(content=text))]
    )


def _note_fallback(stage: str, model: str, reason: str) -> None:
    # WARNING once per process per reason (not per answer); a breadcrumb on
    # every fallback so a later Sentry event shows the fallback model judged.
    if reason not in _fallback_warned:
        _fallback_warned.add(reason)
        logger.warning(
            "Answer-path %s: %s unavailable (%s), using %s",
            stage,
            model,
            reason,
            FALLBACK_MODEL,
        )
    sentry_sdk.add_breadcrumb(
        category="llm",
        level="warning",
        message=f"{stage}: {model} -> {FALLBACK_MODEL} ({reason})",
    )


def _report(stage: str, model: str | None, exc: BaseException) -> None:
    # Error class and status only: the provider's message can quote the request,
    # and the request carries the player's answer.
    status = getattr(exc, "status_code", None)
    logger.warning(
        "Answer-path LLM call failed (stage=%s, model=%s, error=%s, status=%s)",
        stage,
        model,
        type(exc).__name__,
        status,
    )
    global _last_reported_at
    now = time.monotonic()
    if (
        _last_reported_at is not None
        and now - _last_reported_at < SENTRY_REPORT_INTERVAL_S
    ):
        return
    _last_reported_at = now
    if not sentry_sdk.get_client().is_active():
        return
    # capture_message, not capture_exception: a captured traceback carries the
    # frames' local variables, which include the player's answer.
    with sentry_sdk.new_scope() as scope:
        scope.fingerprint = ["answer-path-llm-unavailable"]
        scope.set_tag("llm_stage", stage)
        scope.set_tag("llm_gateway", llm_factory.gateway())
        scope.set_tag("llm_error", type(exc).__name__)
        sentry_sdk.capture_message(
            f"LLM provider unavailable on the answer path ({stage}: "
            f"{type(exc).__name__}, status={status})",
            level="error",
        )
