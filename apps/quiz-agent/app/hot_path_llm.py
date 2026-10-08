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

- ``ATTEMPT_TIMEOUT`` 6 s read / 2 s connect per attempt. Normal calls take
  0.5–1 s for the classifier (parser.py's fast-path comment) and 1–3 s for the
  judge (the "1-3 s evaluation" noted on the iOS MCQ skip guard), so 6 s is
  2× the slowest normal call.
- ``MAX_RETRIES`` 1 (SDK default is 2): one quick retry covers a dropped
  connection or a one-off 5xx/429.
- ``CALL_BUDGET_S`` 8 s hard cap on one call, retries included. The SDK can
  sleep up to 60 s on a ``Retry-After`` header; this cap overrides that.

Worst case per answer is two capped calls = 16 s of LLM time; during an
outage the first failing call ends the submit, so usually 8 s.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any

import httpx
import openai
import sentry_sdk
from quiz_shared.llm import factory as llm_factory

from .quiz.errors import JudgeUnavailable

logger = logging.getLogger(__name__)

ATTEMPT_TIMEOUT = httpx.Timeout(6.0, connect=2.0)
MAX_RETRIES = 1
CALL_BUDGET_S = 8.0

# One Sentry event per incident, not one per answer: every player answering
# during an outage hits this, and each would otherwise be its own event.
SENTRY_REPORT_INTERVAL_S = 600.0
_last_reported_at: float | None = None


def client() -> openai.AsyncOpenAI:
    """The async OpenAI-SDK client the answer path uses (active gateway)."""
    return llm_factory.openai_client(async_=True, timeout=ATTEMPT_TIMEOUT).with_options(
        max_retries=MAX_RETRIES
    )


async def complete(llm: Any, *, stage: str, **request: Any) -> Any:
    """``llm.chat.completions.create(**request)`` within ``CALL_BUDGET_S``.

    Raises ``JudgeUnavailable`` when the provider errors or does not answer in
    time, so the submit flow can ask the player again instead of failing.
    """
    try:
        return await asyncio.wait_for(
            llm.chat.completions.create(**request), timeout=CALL_BUDGET_S
        )
    except (TimeoutError, openai.APIError) as exc:
        _report(stage, request.get("model"), exc)
        raise JudgeUnavailable(stage) from exc


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
