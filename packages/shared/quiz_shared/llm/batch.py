"""Provider batch-inference adapter (issue #168, DD7).

Nothing in this repo had ever called a batch endpoint, so DD7 made a
5-request smoke test implementation step 0. Smoke result (2026-09-01, recorded
in ``docs/issues/issue-168-batch-translation-pipeline-sk-cs.md``): **OpenRouter
batch works** — no native-Anthropic fallback is built, because building an
unused second route would be speculation, not safety.

The surface OpenRouter actually serves (verified live, it is *not* the OpenAI
Batch API shape):

- ``POST https://openrouter.ai/api/beta/batches`` — note ``beta``, not ``v1``.
  Requests are inline JSON (``requests: [{custom_id, body}]``); there is no
  JSONL file upload and no ``/files`` step. Returns ``202`` with the job.
- ``GET  .../batches/{id}`` — status plus, once complete, the results **inline**
  in the same payload. There is no separate download endpoint.
- Statuses: ``validating -> in_progress -> finalizing -> completed``; terminal
  set also has ``failed``, ``expired``, ``cancelled``.

Two provider realities the caller must handle, not this module:

1. **Not every model has a batch endpoint.** OpenRouter's model catalog lists
   ``openai/gpt-4.1:batch``, but the batch API rejects that model with
   ``does not have a :batch endpoint`` (Anthropic and Google slugs are
   accepted). That is a hard, reproducible 400, so it gets its own exception
   type — ``BatchModelNotSupported`` — and the caller decides whether to route
   that model synchronously instead of silently swapping in another model
   (standing rule: no model substitution).
2. **Batch is inherently OpenRouter here**, the way audio/image is inherently
   canonical OpenAI in ``factory``. So the model id is mapped through the
   factory's remap table regardless of ``LLM_GATEWAY``; an id the table does
   not know passes through unchanged, which lets a caller force any slug.

Cost follows DD9: the provider's reported spend is surfaced as
``BatchJob.cost_usd``, and an absent usage block yields ``None`` — never a
fake ``0``, which would misprice the "translate in batches as testers grow"
decision.

This is submit/poll/retrieve only — no scheduler, no retry framework, no
persistence. Durable progress is the runner's job (DD7's job JSONL).
"""

from __future__ import annotations

import os
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any, Optional

import httpx

from . import factory

OPENROUTER_BATCH_URL = "https://openrouter.ai/api/beta/batches"

#: Batch jobs are minutes-to-hours; the HTTP calls themselves are small, but a
#: submit carrying a few hundred inline requests is a real upload.
DEFAULT_TIMEOUT = 120.0

#: Statuses after which polling is pointless.
TERMINAL_STATUSES = frozenset({"completed", "failed", "expired", "cancelled"})

#: The four API shapes OpenRouter's batch service accepts.
BATCH_ENDPOINTS = (
    "/v1/chat/completions",
    "/v1/responses",
    "/v1/messages",
    "/v1/embeddings",
)


class BatchError(RuntimeError):
    """Any batch call that did not do what it was asked to do."""


class BatchModelNotSupported(BatchError):
    """The provider has no batch endpoint for this model.

    Distinct from a generic failure because it is a *routing* fact, not a
    transient error: the caller must either run this model synchronously or
    stop and ask. It must never quietly become a different model.
    """


@dataclass(frozen=True)
class BatchRequest:
    """One unit of work. ``custom_id`` is how the result is matched back."""

    custom_id: str
    body: Mapping[str, Any]

    def as_payload(self) -> dict[str, Any]:
        return {"custom_id": self.custom_id, "body": dict(self.body)}


@dataclass(frozen=True)
class BatchResult:
    """One completed request. ``content`` is the assistant text, when there is one."""

    custom_id: str
    status_code: Optional[int]
    content: Optional[str]
    error: Optional[Any]

    @property
    def ok(self) -> bool:
        return (
            self.error is None and self.status_code == 200 and self.content is not None
        )


@dataclass(frozen=True)
class BatchJob:
    """A submitted batch as the provider currently sees it."""

    id: str
    status: str
    model: str
    endpoint: str
    request_counts: Mapping[str, int] = field(default_factory=dict)
    #: Provider-reported spend in USD, or ``None`` when unavailable (DD9).
    cost_usd: Optional[float] = None
    raw: Mapping[str, Any] = field(default_factory=dict)

    @property
    def is_terminal(self) -> bool:
        return self.status in TERMINAL_STATUSES

    @property
    def failed_count(self) -> int:
        return int(self.request_counts.get("failed", 0) or 0)


def to_openrouter_slug(model: str) -> str:
    """Direct model id -> OpenRouter slug, regardless of ``LLM_GATEWAY``.

    Batch only exists on OpenRouter for us, so — mirroring ``factory``'s
    ``direct=True`` carve-out in the opposite direction — the gateway toggle
    has no say here. Unknown ids pass through so a caller can force a slug.
    """
    return factory._REMAP_OPENROUTER.get(model, model)


def _api_key() -> str:
    key = os.getenv("OPENROUTER_API_KEY")
    if not key:
        raise BatchError(
            "OPENROUTER_API_KEY is not set — the batch adapter routes through "
            "OpenRouter regardless of LLM_GATEWAY (see module docstring)."
        )
    return key


def _headers() -> dict[str, str]:
    return {
        "Authorization": f"Bearer {_api_key()}",
        "Content-Type": "application/json",
    }


def _client(client: Optional[httpx.Client]) -> tuple[httpx.Client, bool]:
    if client is not None:
        return client, False
    return httpx.Client(timeout=DEFAULT_TIMEOUT), True


def _job_from_payload(payload: Mapping[str, Any]) -> BatchJob:
    usage = payload.get("usage") or {}
    cost = usage.get("cost")
    return BatchJob(
        id=payload["id"],
        status=payload.get("status", "unknown"),
        model=payload.get("model", ""),
        endpoint=payload.get("endpoint", ""),
        request_counts=payload.get("request_counts") or {},
        cost_usd=float(cost) if cost is not None else None,
        raw=payload,
    )


def _raise_for_status(response: httpx.Response, what: str) -> None:
    if response.status_code < 300:
        return
    text = response.text[:500]
    if response.status_code == 400 and "does not have a :batch endpoint" in text:
        raise BatchModelNotSupported(text)
    raise BatchError(f"{what} failed with HTTP {response.status_code}: {text}")


def submit(
    model: str,
    requests: Sequence[BatchRequest],
    *,
    endpoint: str = "/v1/chat/completions",
    client: Optional[httpx.Client] = None,
) -> BatchJob:
    """Create a batch job. Raises rather than returning a half-made job."""
    if not requests:
        raise BatchError("submit() needs at least one request")
    if endpoint not in BATCH_ENDPOINTS:
        raise BatchError(f"endpoint must be one of {BATCH_ENDPOINTS}, got {endpoint!r}")
    seen = {r.custom_id for r in requests}
    if len(seen) != len(requests):
        raise BatchError(
            "custom_id values must be unique — results are matched by them"
        )

    http, owned = _client(client)
    try:
        response = http.post(
            OPENROUTER_BATCH_URL,
            headers=_headers(),
            json={
                "endpoint": endpoint,
                "model": to_openrouter_slug(model),
                "requests": [r.as_payload() for r in requests],
            },
        )
        _raise_for_status(response, "batch submit")
        return _job_from_payload(response.json())
    finally:
        if owned:
            http.close()


def poll(job_id: str, *, client: Optional[httpx.Client] = None) -> BatchJob:
    """Current state of a batch job. One HTTP GET, no waiting, no retries."""
    http, owned = _client(client)
    try:
        response = http.get(f"{OPENROUTER_BATCH_URL}/{job_id}", headers=_headers())
        _raise_for_status(response, "batch poll")
        return _job_from_payload(response.json())
    finally:
        if owned:
            http.close()


def _content_of(item: Mapping[str, Any]) -> Optional[str]:
    body = (item.get("response") or {}).get("body") or {}
    choices = body.get("choices") or []
    if not choices:
        return None
    return (choices[0].get("message") or {}).get("content")


def retrieve(job: BatchJob) -> list[BatchResult]:
    """Results of a *completed* job, parsed out of the poll payload.

    Takes the job rather than an id because OpenRouter ships results inline
    with the status — re-fetching would be a second charge-free but pointless
    round trip, and it would let a caller read results from a job it never
    checked the status of.
    """
    if job.status != "completed":
        raise BatchError(
            f"batch {job.id} is {job.status!r}, not 'completed' — refusing to "
            "read results from an unfinished or failed job"
        )
    results = job.raw.get("results")
    if results is None:
        raise BatchError(f"batch {job.id} is completed but carries no results block")
    return [
        BatchResult(
            custom_id=item.get("custom_id", ""),
            status_code=(item.get("response") or {}).get("status_code"),
            content=_content_of(item),
            error=item.get("error"),
        )
        for item in results
    ]
