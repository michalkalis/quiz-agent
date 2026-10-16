"""Remote app switches stored in the DB (#207 task 207.18).

The switches served by ``GET /app-config`` (minimum versions, custom-pack
orders, the notice) used to live only in env / Fly secrets, so flipping one
restarted the single quiz-agent machine mid-quiz. Now a row in
``app_switches`` overrides the env value and is changed through
``PUT /admin/app-switches`` with no restart; without a row the env value
(the old behavior) still applies. quiz-pack-api reads ``orders_enabled`` from
the same table to refuse new orders server-side.

Reads are cached in-process for ~60 s (the route is hit at every launch);
a write clears the cache, so the change is live on the next request. Fail
open: a broken or slow read keeps the last value, and with no value at all
the env switches apply.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any

from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert

from .config import _VERSION_RE, Settings
from .db.models import AppSwitch

logger = logging.getLogger(__name__)

CACHE_SECONDS = 60.0
READ_TIMEOUT_SECONDS = 1.0
NOTICE_MAX_CHARS = 300

VERSION_KEYS = ("min_version_app_store", "min_version_testflight")
NOTICE_KEYS = ("notice_sk", "notice_cs", "notice_en")
KEYS = (*VERSION_KEYS, "orders_enabled", *NOTICE_KEYS)

_cache: tuple[float, dict[str, str | None]] | None = None
_lock = asyncio.Lock()


def reset_cache() -> None:
    global _cache, _lock
    _cache = None
    _lock = asyncio.Lock()


def encode(key: str, value: Any) -> str | None:
    """Validate one admin value and turn it into the stored text.

    ``None`` / blank = "switched off" (no minimum, no notice). Raises
    ``ValueError`` on anything else that is wrong, so a typo is refused at
    write time instead of being served to every installed build.
    """
    if key not in KEYS:
        raise ValueError(f"unknown switch {key!r}")
    if key == "orders_enabled":
        if not isinstance(value, bool):
            raise ValueError("orders_enabled must be true or false")
        return "true" if value else "false"
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{key} must be a string or null")
    text = value.strip()
    if not text:
        return None
    if key in VERSION_KEYS and not _VERSION_RE.fullmatch(text):
        raise ValueError(f"{key} must look like 1.2 or 1.2.3, got {text!r}")
    if key in NOTICE_KEYS and len(text) > NOTICE_MAX_CHARS:
        raise ValueError(f"{key} is longer than {NOTICE_MAX_CHARS} characters")
    return text


def env_values(settings: Settings) -> dict[str, Any]:
    return {
        "min_version_app_store": settings.min_app_version_app_store,
        "min_version_testflight": settings.min_app_version_testflight,
        "orders_enabled": settings.pack_orders_enabled,
        "notice_sk": settings.app_notice_sk,
        "notice_cs": settings.app_notice_cs,
        "notice_en": settings.app_notice_en,
    }


def effective(settings: Settings, overrides: dict[str, str | None]) -> dict[str, Any]:
    """Env values with every DB override applied on top."""
    out = env_values(settings)
    for key, raw in overrides.items():
        if key == "orders_enabled":
            out[key] = raw != "false"
        elif key in out:
            out[key] = raw
    return out


async def read_overrides(sessionmaker) -> dict[str, str | None]:
    async with sessionmaker() as session:
        rows = (await session.execute(select(AppSwitch))).scalars().all()
    return {r.key: r.value for r in rows if r.key in KEYS}


async def cached_overrides(sessionmaker) -> dict[str, str | None]:
    """Overrides for ``GET /app-config``: cached, capped at 1 s, fail open."""
    global _cache
    if sessionmaker is None:
        return {}
    if _cache is not None and _cache[0] > time.monotonic():
        return _cache[1]
    async with _lock:
        if _cache is not None and _cache[0] > time.monotonic():
            return _cache[1]
        stale = _cache[1] if _cache is not None else {}
        try:
            value = await asyncio.wait_for(
                read_overrides(sessionmaker), READ_TIMEOUT_SECONDS
            )
        except Exception as e:  # never the reason app-config fails or stalls
            logger.warning("app switches read failed: %r", e)
            value = stale
        _cache = (time.monotonic() + CACHE_SECONDS, value)
        return value


async def write(
    sessionmaker, set_values: dict[str, Any], reset: list[str]
) -> dict[str, str | None]:
    """Upsert ``set_values`` (validated), delete ``reset`` keys, clear the cache."""
    encoded = {k: encode(k, v) for k, v in set_values.items()}
    unknown = [k for k in reset if k not in KEYS]
    if unknown:
        raise ValueError(f"unknown switch {unknown[0]!r}")
    async with sessionmaker() as session:
        for key, value in encoded.items():
            stmt = insert(AppSwitch).values(key=key, value=value)
            await session.execute(
                stmt.on_conflict_do_update(
                    index_elements=[AppSwitch.key],
                    set_={"value": stmt.excluded.value, "updated_at": func.now()},
                )
            )
        if reset:
            await session.execute(delete(AppSwitch).where(AppSwitch.key.in_(reset)))
        await session.commit()
    reset_cache()
    return await read_overrides(sessionmaker)
