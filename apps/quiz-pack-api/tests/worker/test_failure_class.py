"""Which pack failures may be retried (#207 207.20, Redis-loss drill finding).

WHY: a failed attempt that is not final is re-driven by the stuck-order sweep,
and every re-drive is a paid pipeline run. The drill showed a 401 order
re-driven every ~20 min until the attempt budget cut it off. These tests pin
the line: errors no retry can fix (rejected key, invalid request, exhausted
balance) are non-retryable; transient ones (timeouts, 5xx, rate limits,
anything unrecognised) stay retryable, so recovery is never weakened by the
classifier guessing.
"""

from __future__ import annotations

import anthropic
import httpx
import openai
import pytest
from tavily import errors as tavily_errors

from app.worker.failure_class import non_retryable_reason

_REQ = httpx.Request("POST", "https://openrouter.ai/api/v1/chat/completions")


def _openai_status(cls: type[openai.APIStatusError], code: int) -> openai.APIStatusError:
    return cls("provider said no", response=httpx.Response(code, request=_REQ), body=None)


def _anthropic_status(
    cls: type[anthropic.APIStatusError], code: int
) -> anthropic.APIStatusError:
    return cls("provider said no", response=httpx.Response(code, request=_REQ), body=None)


class _BotoLikeError(Exception):
    """Shape of botocore's ClientError (Bedrock): a dict ``response``."""

    def __init__(self, code: str, http: int) -> None:
        super().__init__(code)
        self.response = {
            "Error": {"Code": code},
            "ResponseMetadata": {"HTTPStatusCode": http},
        }


@pytest.mark.parametrize(
    "exc",
    [
        # The exact drill failure: OpenRouter with a disabled key.
        _openai_status(openai.AuthenticationError, 401),
        _openai_status(openai.PermissionDeniedError, 403),
        _openai_status(openai.BadRequestError, 400),
        _openai_status(openai.NotFoundError, 404),
        _openai_status(openai.APIStatusError, 402),  # OpenRouter: balance exhausted
        _anthropic_status(anthropic.AuthenticationError, 401),
        _BotoLikeError("AccessDeniedException", 403),
        httpx.HTTPStatusError("x", request=_REQ, response=httpx.Response(401, request=_REQ)),
        tavily_errors.InvalidAPIKeyError("bad key"),
        tavily_errors.UsageLimitExceededError("plan used up"),
    ],
    ids=lambda e: type(e).__name__,
)
def test_failures_a_retry_cannot_fix_are_non_retryable(exc: BaseException) -> None:
    assert non_retryable_reason(exc) is not None


@pytest.mark.parametrize(
    "exc",
    [
        _openai_status(openai.RateLimitError, 429),
        _openai_status(openai.InternalServerError, 500),
        _openai_status(openai.APIStatusError, 408),
        _anthropic_status(anthropic.APIStatusError, 529),  # Anthropic overloaded
        openai.APITimeoutError(request=_REQ),
        openai.APIConnectionError(request=_REQ),
        _BotoLikeError("ThrottlingException", 429),
        TimeoutError("stage 'generating' exceeded STAGE_TIMEOUT_SECONDS"),
        RuntimeError("F8 violated: all 5 questions ungrounded"),
        tavily_errors.TimeoutError(10.0),
    ],
    ids=lambda e: type(e).__name__,
)
def test_transient_or_unknown_failures_stay_retryable(exc: BaseException) -> None:
    # Unknown means retryable: the classifier may only ever shorten the retry
    # path for errors it positively recognises, never for our own bugs/outages.
    assert non_retryable_reason(exc) is None


def test_a_stage_error_raised_from_a_rejected_key_is_non_retryable() -> None:
    """Pipeline code that wraps a provider error must not hide the 401."""
    try:
        try:
            raise _openai_status(openai.AuthenticationError, 401)
        except openai.AuthenticationError as inner:
            raise RuntimeError("sourcing failed") from inner
    except RuntimeError as outer:
        assert non_retryable_reason(outer) is not None


def test_the_outermost_status_decides() -> None:
    """A 5xx raised while handling an earlier 401 is judged by the 5xx: retryable."""
    try:
        try:
            raise _openai_status(openai.AuthenticationError, 401)
        except openai.AuthenticationError:
            raise _openai_status(openai.InternalServerError, 502)
    except openai.InternalServerError as outer:
        assert outer.__context__ is not None  # premise: the 401 is in the chain
        assert non_retryable_reason(outer) is None
