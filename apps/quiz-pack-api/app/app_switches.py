"""The live custom-pack orders switch (#207 task 207.18).

quiz-agent keeps the remote app switches in the shared DB table
``app_switches`` (its migration ``0015_app_switches``) and changes them with
``PUT /admin/app-switches`` without a restart. The row ``orders_enabled``
overrides this app's ``PACK_ORDERS_ENABLED`` env value too, so pausing orders
in one place refuses them server-side as well, also for builds that ignore
``/app-config``.

Read per order creation (rare, one primary-key lookup), inside a savepoint so
a missing table or a broken read never aborts the order's transaction; any
failure falls back to the env value.
"""

from __future__ import annotations

import logging

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from .config import Settings

logger = logging.getLogger(__name__)

_QUERY = text("SELECT value FROM app_switches WHERE key = 'orders_enabled'")


async def orders_enabled(session: AsyncSession, settings: Settings) -> bool:
    try:
        async with session.begin_nested():
            raw = (await session.execute(_QUERY)).scalar_one_or_none()
    except Exception as e:
        logger.warning("orders switch read failed, using env value: %r", e)
        return settings.pack_orders_enabled
    if raw is None:  # no override row
        return settings.pack_orders_enabled
    return raw != "false"
