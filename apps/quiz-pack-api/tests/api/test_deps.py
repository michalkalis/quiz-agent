"""Regression tests for `app.api.deps.get_arq_pool`.

Background: a previous Upstash CDG flake stacked concurrent `create_pool`
retries on a 256 MB web VM and OOM-killed uvicorn. The fix in this module
adds a single-flight lock so concurrent requests share one in-flight pool
attempt, plus a tight retry/timeout config so a failing attempt 503s fast.
These tests pin both behaviors.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException

from app.api import deps


def _make_request(pool):
    """Build a minimal stand-in for the FastAPI Request that get_arq_pool reads."""
    return SimpleNamespace(app=SimpleNamespace(state=SimpleNamespace(arq_pool=pool)))


@pytest.fixture(autouse=True)
def _reset_lock():
    """Replace the module-level lock so each test gets a fresh one bound to the
    current event loop (asyncio.Lock binds to the running loop on first await).
    """
    original = deps._arq_pool_lock
    deps._arq_pool_lock = asyncio.Lock()
    yield
    deps._arq_pool_lock = original


@pytest.mark.asyncio
async def test_returns_existing_pool_without_creating_a_new_one():
    """If startup put a pool on state, that's what we return — no create_pool call."""
    existing = MagicMock(name="existing_pool")
    request = _make_request(existing)

    with patch.object(deps, "create_pool", new=AsyncMock()) as mock_create:
        result = await deps.get_arq_pool(request)

    assert result is existing
    mock_create.assert_not_awaited()


@pytest.mark.asyncio
async def test_lazy_create_when_pool_is_none_succeeds():
    """Pool absent at startup (Upstash was flaky) → first request creates it lazily."""
    new_pool = MagicMock(name="new_pool")
    request = _make_request(None)

    with patch.object(deps, "create_pool", new=AsyncMock(return_value=new_pool)) as mock_create:
        result = await deps.get_arq_pool(request)

    assert result is new_pool
    assert request.app.state.arq_pool is new_pool  # cached for next call
    mock_create.assert_awaited_once()


@pytest.mark.asyncio
async def test_lazy_create_failure_returns_503():
    """Upstash still unreachable → 503 to client, pool stays None for retry."""
    request = _make_request(None)

    failing = AsyncMock(side_effect=ConnectionError("upstash unreachable"))
    with patch.object(deps, "create_pool", new=failing):
        with pytest.raises(HTTPException) as exc_info:
            await deps.get_arq_pool(request)

    assert exc_info.value.status_code == 503
    assert request.app.state.arq_pool is None  # not poisoned with a bad value


@pytest.mark.asyncio
async def test_concurrent_requests_share_one_create_pool_attempt():
    """The lock is the OOM fix: 10 concurrent requests during a flake must result
    in ONE create_pool call, not 10 stacked retry storms.
    """
    new_pool = MagicMock(name="new_pool")
    create_started = asyncio.Event()
    release_create = asyncio.Event()

    async def slow_create(_settings):
        create_started.set()
        await release_create.wait()
        return new_pool

    request = _make_request(None)
    mock_create = AsyncMock(side_effect=slow_create)

    with patch.object(deps, "create_pool", new=mock_create):
        # Fire 10 concurrent get_arq_pool callers. The first will enter the
        # lock + slow_create; the other 9 must wait on the lock, not each
        # call create_pool themselves.
        tasks = [asyncio.create_task(deps.get_arq_pool(request)) for _ in range(10)]
        await create_started.wait()
        release_create.set()
        results = await asyncio.gather(*tasks)

    # If the lock failed, each task would have called create_pool itself
    # (await_count == 10) — that's the OOM scenario we're guarding against.
    assert mock_create.await_count == 1, "lock failed — multiple create_pool calls stacked"
    assert all(r is new_pool for r in results)


@pytest.mark.asyncio
async def test_fast_fail_settings_tighten_retry_and_timeout():
    """The point of _redis_settings_fast_fail is bounded latency on a doomed attempt.
    Pinning the values prevents an accidental return to arq defaults (5 retries
    × ~5 s each = 30 s blocked request, the original OOM trigger).
    """
    rs = deps._redis_settings_fast_fail("redis://localhost:6379")

    assert rs.conn_retries == 1
    assert rs.conn_timeout == 2
