"""Background monitors run on exactly one machine (#207.20, design step 5).

Why: with two machines every monitor would run twice — two e-mails per alert,
two paid balance-API calls per hour. And when the machine running them dies
(``fly machine kill``, host failure) the other must take over within ~2 min,
or outages go unreported exactly when a host is failing.
"""

from __future__ import annotations

import asyncio

import pytest
from app.coordination.leases import LeaseStore
from app.monitoring.leader import LEASE_NAME, MonitorLeader

pytestmark = pytest.mark.asyncio


class _Machine:
    """One machine's monitors: counts how often they were started/running."""

    def __init__(self, leases: LeaseStore, ttl: float = 0.6) -> None:
        self.started = 0
        self.leader = MonitorLeader(leases, self._start, ttl_s=ttl)

    def _start(self) -> list[asyncio.Task]:
        self.started += 1
        return [asyncio.create_task(asyncio.sleep(3600))]


async def test_only_one_of_two_machines_runs_the_monitors(db_sessionmaker):
    a, b = _Machine(LeaseStore(db_sessionmaker)), _Machine(LeaseStore(db_sessionmaker))
    for _ in range(3):  # several renew rounds, both machines alive
        await a.leader.tick()
        await b.leader.tick()
    assert [a.leader.is_leader, b.leader.is_leader] == [True, False]
    assert a.started == 1 and b.started == 0  # renewals do not restart monitors
    await a.leader.resign()


async def test_a_machine_with_every_monitor_off_still_leads_without_restarting(
    db_sessionmaker,
):
    """Staging switches every monitor off: leadership must not depend on there
    being tasks, or each renewal 'becomes leader' again (staging log, 207.20)."""
    starts: list[int] = []

    def _start() -> list[asyncio.Task]:
        starts.append(1)
        return []

    leader = MonitorLeader(LeaseStore(db_sessionmaker), _start, ttl_s=30)
    for _ in range(3):
        await leader.tick()
    assert leader.is_leader and len(starts) == 1
    await leader.resign()


async def test_a_killed_leader_is_replaced_once_its_lease_expires(db_sessionmaker):
    """``fly machine kill`` gives no chance to resign: the lease must expire."""
    a, b = _Machine(LeaseStore(db_sessionmaker)), _Machine(LeaseStore(db_sessionmaker))
    await a.leader.tick()
    await b.leader.tick()
    assert not b.leader.is_leader
    # a dies silently (no resign, no more renewals)
    await asyncio.sleep(0.8)
    await b.leader.tick()
    assert b.leader.is_leader
    await b.leader.resign()


async def test_a_clean_shutdown_hands_over_at_once(db_sessionmaker):
    a, b = (
        _Machine(LeaseStore(db_sessionmaker), ttl=30),
        _Machine(LeaseStore(db_sessionmaker), ttl=30),
    )
    await a.leader.tick()
    await a.leader.resign()  # deploy stops a: lease released
    await b.leader.tick()
    assert b.leader.is_leader
    await b.leader.resign()


async def test_a_leader_that_lost_its_lease_stops_its_monitors(db_sessionmaker):
    """Never two monitor sets for longer than one renew interval: a machine
    that finds the lease taken (it was cut off longer than the ttl) stops."""
    leases = LeaseStore(db_sessionmaker)
    a = _Machine(leases)
    await a.leader.tick()
    task = a.leader._tasks[0]
    await asyncio.sleep(0.8)  # a's lease expired while it could not renew
    assert await leases.try_acquire(LEASE_NAME, "machine-b", 30)
    await a.leader.tick()
    await asyncio.sleep(0)
    assert not a.leader.is_leader
    assert task.cancelled()


class _FlakyLeases(LeaseStore):
    def __init__(self, sm) -> None:
        super().__init__(sm)
        self.down = False

    async def try_acquire(self, name, holder, ttl_s):
        if self.down:
            raise ConnectionError("db blip")
        return await super().try_acquire(name, holder, ttl_s)


async def test_a_db_blip_shorter_than_the_lease_keeps_the_monitors(db_sessionmaker):
    leases = _FlakyLeases(db_sessionmaker)
    a = _Machine(leases, ttl=30)
    await a.leader.tick()
    leases.down = True
    await a.leader.tick()
    assert a.leader.is_leader and a.started == 1
    leases.down = False
    await a.leader.resign()
