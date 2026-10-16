"""Can a failed pack attempt succeed if we simply try again? (#207 207.20)

WHY: every attempt at a custom-pack order is a paid pipeline run, and a failed
attempt that is not the last one leaves the order ``in_progress`` for the
stuck-order sweep to re-drive ~20 min later. That is right for a timeout, a
5xx, a rate limit or a dead worker. It is pure loss for a failure no retry can
fix: a rejected provider key (401/403), a request the provider calls invalid
(400/404/422), or an exhausted provider balance (402). The 2026-10-16 Redis
drill caught exactly that: a 401 order re-driven every ~20 min until the #145
attempt budget stopped it, each re-drive another paid attempt on prod.

The verdict comes only from what the error itself says, the HTTP status the
provider answered with. Anything without one (our own pipeline errors, judge
outages, connection drops) stays retryable, so today's retry behaviour is
unchanged for every failure this module does not positively recognise.
"""

from __future__ import annotations

from tavily import errors as tavily_errors

# Client errors that a retry of the same request cannot fix. The 4xx codes
# left out are the ones that mean "try again": 408 timeout, 409 conflict,
# 425 too early, 429 rate limit.
_RETRYABLE_4XX = frozenset({408, 409, 425, 429})

# Tavily's client raises status-less exceptions; these name a key, plan or
# request problem (its timeout error is deliberately not here).
_NON_RETRYABLE_TYPES: tuple[type[BaseException], ...] = (
    tavily_errors.InvalidAPIKeyError,
    tavily_errors.MissingAPIKeyError,
    tavily_errors.ForbiddenError,
    tavily_errors.BadRequestError,
    tavily_errors.UsageLimitExceededError,
)


def _http_status(exc: BaseException) -> int | None:
    """The provider's HTTP status, for the SDKs the pipeline talks through.

    openai / anthropic ``APIStatusError`` carry ``status_code``; httpx
    ``HTTPStatusError`` carries ``response.status_code``; botocore
    ``ClientError`` (Bedrock) carries a dict ``response``.
    """
    code = getattr(exc, "status_code", None)
    if isinstance(code, int):
        return code
    response = getattr(exc, "response", None)
    code = getattr(response, "status_code", None)
    if isinstance(code, int):
        return code
    if isinstance(response, dict):
        code = response.get("ResponseMetadata", {}).get("HTTPStatusCode")
        if isinstance(code, int):
            return code
    return None


def _chain(exc: BaseException):
    """The exception and what it was raised from, outermost first."""
    seen: set[int] = set()
    current: BaseException | None = exc
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        yield current
        current = current.__cause__ or (
            None if current.__suppress_context__ else current.__context__
        )


def non_retryable_reason(exc: BaseException) -> str | None:
    """Why retrying cannot help, or ``None`` when a retry may succeed.

    Walks the error and what it was raised from; the outermost one that carries
    an HTTP status decides (a 5xx wrapped around a 401 is retryable).
    """
    for err in _chain(exc):
        if isinstance(err, _NON_RETRYABLE_TYPES):
            return f"{type(err).__name__} (provider key, plan or request rejected)"
        status = _http_status(err)
        if status is None:
            continue
        if 400 <= status < 500 and status not in _RETRYABLE_4XX:
            return f"{type(err).__name__} HTTP {status}"
        return None
    return None
