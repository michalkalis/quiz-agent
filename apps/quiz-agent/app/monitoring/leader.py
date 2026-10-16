"""Background monitors run on exactly one quiz-agent machine (#207.20, step 5).

With two machines every monitor would run twice: double e-mails, double paid
balance API calls. One machine holds the ``monitors`` lease (a Postgres row
with an expiry, ``app.coordination.leases``) and runs them; it renews every
``ttl/3``. When the holder dies the lease expires and another machine starts
the monitors within ``ttl`` + one renew interval. Nothing depends on a
database connection staying open (HAProxy cuts idle ones after 30 min).

A holder that cannot renew (DB unreachable) stops its monitors once its lease
would have expired, so two machines never run them at the same time for
longer than one renew interval.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Callable

from ..coordination.leases import LeaseStore, new_holder

logger = logging.getLogger(__name__)

LEASE_NAME = "monitors"
DEFAULT_TTL_S = 90.0

StartMonitors = Callable[[], list[asyncio.Task]]


class MonitorLeader:
    def __init__(
        self,
        leases: LeaseStore,
        start_monitors: StartMonitors,
        ttl_s: float = DEFAULT_TTL_S,
    ) -> None:
        self._leases = leases
        self._start = start_monitors
        self.ttl_s = ttl_s
        self.holder = new_holder()
        self._tasks: list[asyncio.Task] = []
        self._held_until = 0.0  # monotonic

    @property
    def is_leader(self) -> bool:
        return bool(self._tasks)

    async def tick(self) -> None:
        """One renew attempt; starts or stops the monitors accordingly."""
        now = time.monotonic()
        try:
            held = await self._leases.try_acquire(LEASE_NAME, self.holder, self.ttl_s)
        except Exception:  # noqa: BLE001 — treated as "not renewed"
            logger.warning("Monitor lease renew failed", exc_info=True)
            held = None
        if held:
            self._held_until = now + self.ttl_s
            if not self._tasks:
                logger.info("Monitor leader: this machine runs the monitors")
                self._tasks = self._start()
            return
        if held is None and now < self._held_until:
            return  # DB blip: our lease is still valid, keep running
        if self._tasks:
            logger.info("Monitor leader: lease lost, stopping the monitors")
            self._stop()

    def _stop(self) -> None:
        for task in self._tasks:
            task.cancel()
        self._tasks = []

    async def run(self) -> None:
        try:
            while True:
                await self.tick()
                await asyncio.sleep(self.ttl_s / 3)
        finally:
            self._stop()

    async def resign(self) -> None:
        """On shutdown: stop and free the lease so the other machine takes
        over at once instead of after ``ttl``."""
        self._stop()
        try:
            await self._leases.release(LEASE_NAME, self.holder)
        except Exception:  # noqa: BLE001 — it expires on its own
            logger.warning("Monitor lease release failed", exc_info=True)
