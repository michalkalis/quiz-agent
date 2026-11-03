"""Sentry severity of a cancelled pack attempt (trubbo-triage #11).

WHY: every deploy or Fly machine restart SIGTERMs the worker, and ARQ cancels
the running pack job at once. On a non-final attempt nothing is lost — ARQ or
the stuck-order sweep re-drives the order — yet the cancel reached Sentry as
an error, indistinguishable from a broken pipeline, so routine deploys paged
as incidents. The final attempt is different: the order ends failed and
refund-eligible, which must stay an error. Real (non-cancel) failures keep
their error level on every attempt.

No database needed: ``_handle_failure`` only reads/writes two rows, stubbed
here, so this runs in the default (non-integration) suite.
"""

from __future__ import annotations

import uuid
from types import SimpleNamespace
from typing import Any

import pytest

from app.worker import tasks
from app.worker.worker import WorkerSettings


class _StubSession:
    def __init__(self, order: Any, job: Any) -> None:
        self._rows = {"order": order, "job": job}

    async def __aenter__(self) -> "_StubSession":
        return self

    async def __aexit__(self, *_exc: Any) -> None:
        return None

    async def get(self, model: Any, _key: Any) -> Any:
        return self._rows["order" if model is tasks.GenerationOrder else "job"]

    async def commit(self) -> None:
        return None


@pytest.fixture
def captured_levels(monkeypatch: pytest.MonkeyPatch) -> list[str | None]:
    levels: list[str | None] = []
    monkeypatch.setattr(
        tasks.sentry_sdk,
        "capture_exception",
        lambda exc, level=None, **_kw: levels.append(level),
    )

    async def _no_pack(*_a: Any, **_kw: Any) -> None:
        return None

    monkeypatch.setattr(tasks, "fail_pack_in_session", _no_pack)
    return levels


async def _fail(job_try: int, exc: Exception, *, cancelled: bool) -> Any:
    order = SimpleNamespace(
        job_id=uuid.uuid4(), status="in_progress", refund_eligible=False
    )
    job = SimpleNamespace(
        retry_count=0, cumulative_cost_cents=0, progress=10, step_log=[],
        status="running", error=None,
    )
    ctx = {"job_try": job_try, "session_factory": lambda: _StubSession(order, job)}
    kwargs = {"cancelled": True} if cancelled else {}
    await tasks._handle_failure(ctx, uuid.uuid4(), "order", None, exc, **kwargs)
    return order


_CANCEL = TimeoutError("process_order cancelled at stage 'topup'")


async def test_shutdown_cancel_on_retryable_attempt_is_a_warning(
    captured_levels: list[str | None],
) -> None:
    order = await _fail(1, _CANCEL, cancelled=True)
    assert order.status == "in_progress"  # still retried, nothing lost
    assert captured_levels == ["warning"]


async def test_cancel_on_final_attempt_stays_an_error(
    captured_levels: list[str | None],
) -> None:
    order = await _fail(WorkerSettings.max_tries, _CANCEL, cancelled=True)
    assert order.status == "failed" and order.refund_eligible is True
    assert captured_levels == ["error"]


async def test_real_failure_on_first_attempt_stays_an_error(
    captured_levels: list[str | None],
) -> None:
    await _fail(1, RuntimeError("judge panel crashed"), cancelled=False)
    assert captured_levels == ["error"]
