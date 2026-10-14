"""The experiment block served in ``GET /app-config`` (#204 task 204.9).

That route is public and hit on every launch and foreground, so the rows are
cached in-process for ~60 s instead of read per request, one request
refreshes while the others wait on a lock (no stampede at expiry), and the
read is capped at 1 s. Fail open: no DB, a slow or broken read → the last
value served (``None`` if there never was one), and the app falls back to its
manual switches.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any

from sqlalchemy import select

from ..db.models import VoiceExperimentArm

logger = logging.getLogger(__name__)

CACHE_SECONDS = 60.0
READ_TIMEOUT_SECONDS = 1.0

# (expires_at monotonic, value); a failed read is cached too, so a sick DB is
# asked at most once a minute by this route.
_cache: tuple[float, dict | None] | None = None
_lock = asyncio.Lock()


def reset_cache() -> None:
    global _cache, _lock
    _cache = None
    _lock = asyncio.Lock()


async def _read(sessionmaker) -> dict[str, dict[str, dict[str, Any]]]:
    async with sessionmaker() as session:
        rows = (await session.execute(select(VoiceExperimentArm))).scalars().all()
    out: dict[str, dict[str, dict[str, Any]]] = {}
    for r in rows:
        out.setdefault(r.flag, {})[r.route_group] = {
            "status": r.status,
            "p_on": r.p_on,
            "generation": r.generation,
        }
    return out


async def voice_experiment_config(sessionmaker) -> dict | None:
    """``{flag: {route_group: {status, p_on, generation}}}`` or ``None``."""
    global _cache
    if sessionmaker is None:
        return None
    if _cache is not None and _cache[0] > time.monotonic():
        return _cache[1]
    async with _lock:
        # Another request may have refreshed while this one waited.
        if _cache is not None and _cache[0] > time.monotonic():
            return _cache[1]
        stale = _cache[1] if _cache is not None else None
        try:
            value: dict | None = (
                await asyncio.wait_for(_read(sessionmaker), READ_TIMEOUT_SECONDS)
                or None
            )
        except Exception as e:  # never the reason app-config fails or stalls
            logger.warning("voice experiment config read failed: %r", e)
            value = stale
        _cache = (time.monotonic() + CACHE_SECONDS, value)
        return value
