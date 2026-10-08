"""Deterministic "is the other backend blocked yet?" signal for lock-race tests.

Replaces fixed ``asyncio.sleep`` guesses: poll ``pg_locks`` for an advisory
lock request that has not been granted, which is exactly the state of a backend
waiting on ``pg_advisory_xact_lock``.
"""

from __future__ import annotations

import asyncio

from sqlalchemy import text


async def wait_until_blocked_or_done(
    sessionmaker, task: asyncio.Task, timeout: float = 10.0
) -> bool:
    """Return True once a backend waits on an advisory lock, False if ``task``
    finished first (it never blocked: the un-serialized/bug path). Raises on
    timeout so a hang fails loudly instead of passing by luck."""
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        if task.done():
            return False
        async with sessionmaker() as s:
            waiting = await s.scalar(
                text(
                    "SELECT count(*) FROM pg_locks "
                    "WHERE locktype = 'advisory' AND NOT granted"
                )
            )
        if waiting:
            return True
        await asyncio.sleep(0.01)
    raise TimeoutError("no backend blocked on an advisory lock and task still running")
