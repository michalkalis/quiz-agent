"""The experiment block served in ``GET /app-config`` (#204 task 204.9).

That route is public and hit on every launch and foreground, so the rows are
cached in-process for ~60 s instead of read per request. Fail open: no DB or
any read error → ``None``, and the app falls back to its manual switches.
"""

from __future__ import annotations

import logging
import time
from typing import Any

from sqlalchemy import select

from ..db.models import VoiceExperimentArm

logger = logging.getLogger(__name__)

CACHE_SECONDS = 60.0

# (expires_at monotonic, value); a failed read is cached too, so a sick DB is
# asked at most once a minute by this route.
_cache: tuple[float, dict | None] | None = None


def reset_cache() -> None:
    global _cache
    _cache = None


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
    now = time.monotonic()
    if _cache is not None and _cache[0] > now:
        return _cache[1]
    try:
        value: dict | None = await _read(sessionmaker) or None
    except Exception as e:  # never the reason app-config fails
        logger.warning("voice experiment config read failed: %s", e)
        value = None
    _cache = (now + CACHE_SECONDS, value)
    return value
