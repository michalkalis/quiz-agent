"""mba backup worker (#207 207.5 — Fly worker primary, mba only a backup).

Founder 2026-10-16: paid packs run on the Fly worker (Anthropic API); the mba
session worker may take an order only when the Fly worker is gone or an order
sits unclaimed. These tests pin the two ways that could go wrong: the backup
stepping in while Fly copes (a deploy restart, a long pack run on Fly), and
the backup staying out while an order is stranded.
"""

from __future__ import annotations

import asyncio
from typing import Any

import pytest
from app.config import BACKUP_HEALTH_CHECK_KEY
from app.worker import backup
from app.worker.backup import BackupGate, build_worker, run_gate
from arq.constants import default_queue_name, in_progress_key_prefix

FLY_KEY = default_queue_name + ":health-check"
GRACE_S = 300
WAIT_S = 900
NOW_MS = 10_000_000_000.0


class _FakeRedis:
    """Just enough ArqRedis: key existence + the queue sorted set."""

    def __init__(self, keys: set[str] | None = None, queue: dict[str, float] | None = None):
        self.keys = keys or set()
        self.queue = queue or {}

    async def exists(self, key: str) -> int:
        return int(key in self.keys)

    async def zrangebyscore(self, name, min, max, start=None, num=None, withscores=False):
        assert name == default_queue_name
        rows = sorted((s, j) for j, s in self.queue.items() if min <= s <= max)
        return [(j.encode(), s) for s, j in rows][start : start + num]


class _Clock:
    def __init__(self) -> None:
        self.t = 0.0

    def __call__(self) -> float:
        return self.t


def _gate(clock: _Clock | None = None) -> BackupGate:
    return BackupGate(
        default_queue_name,
        fly_down_grace_s=GRACE_S,
        queue_wait_s=WAIT_S,
        monotonic=clock or _Clock(),
        wall_ms=lambda: NOW_MS,
    )


async def test_stays_out_while_the_fly_worker_has_a_heartbeat() -> None:
    # Normal day: Fly generates on the API; the subscription is not touched.
    assert await _gate().reason_to_take_over(_FakeRedis(keys={FLY_KEY})) is None


async def test_a_deploy_restart_does_not_trigger_a_takeover() -> None:
    # A deploy drops the Fly heartbeat for ~1-2 min; taking over then would
    # start session runs on every deploy.
    clock = _Clock()
    gate = _gate(clock)
    redis = _FakeRedis()
    assert await gate.reason_to_take_over(redis) is None
    clock.t = GRACE_S - 1
    assert await gate.reason_to_take_over(redis) is None


async def test_takes_over_once_the_fly_worker_is_gone_past_the_grace() -> None:
    clock = _Clock()
    gate = _gate(clock)
    redis = _FakeRedis()
    await gate.reason_to_take_over(redis)
    clock.t = GRACE_S
    reason = await gate.reason_to_take_over(redis)
    assert reason is not None and "no Fly worker heartbeat" in reason


async def test_a_returning_heartbeat_resets_the_grace() -> None:
    # A flapping Fly worker must get a fresh grace each time, not inherit the
    # first outage's clock.
    clock = _Clock()
    gate = _gate(clock)
    await gate.reason_to_take_over(_FakeRedis())
    clock.t = GRACE_S - 10
    await gate.reason_to_take_over(_FakeRedis(keys={FLY_KEY}))
    clock.t = GRACE_S + 10
    assert await gate.reason_to_take_over(_FakeRedis()) is None


async def test_takes_over_an_order_left_unclaimed_while_fly_is_alive() -> None:
    # Fly alive but busy (two long packs) or wedged: an order unclaimed past
    # the wait is a customer waiting, so the backup helps.
    redis = _FakeRedis(keys={FLY_KEY}, queue={"order-a": NOW_MS - (WAIT_S + 60) * 1000})
    reason = await _gate().reason_to_take_over(redis)
    assert reason is not None and "waited" in reason


async def test_an_order_being_run_is_not_a_waiting_order() -> None:
    # ARQ keeps a running job in the queue set; with its in-progress marker it
    # is Fly's long pack run, not a stranded order.
    redis = _FakeRedis(
        keys={FLY_KEY, in_progress_key_prefix + "order-a"},
        queue={"order-a": NOW_MS - (WAIT_S + 3600) * 1000},
    )
    assert await _gate().reason_to_take_over(redis) is None


async def test_recent_orders_and_cron_jobs_do_not_trigger() -> None:
    redis = _FakeRedis(
        keys={FLY_KEY},
        queue={
            "order-new": NOW_MS - (WAIT_S - 60) * 1000,
            "cron:sweep_stuck_orders:1": NOW_MS - (WAIT_S + 600) * 1000,
        },
    )
    assert await _gate().reason_to_take_over(redis) is None


class _FakeWorker:
    def __init__(self, redis: Any) -> None:
        self.pool = redis
        self.allow_pick_jobs = False


async def test_run_gate_opens_and_closes_pickup_and_reports_the_takeover(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Opening = the backup is generating paid packs on the subscription: the
    # founder hears about it once (Sentry), not on every check.
    captured: list[str] = []
    monkeypatch.setattr(backup.sentry_sdk, "capture_message", lambda m, level: captured.append(m))
    redis = _FakeRedis(keys={FLY_KEY}, queue={"order-a": NOW_MS - (WAIT_S + 60) * 1000})
    worker = _FakeWorker(redis)
    task = asyncio.create_task(run_gate(worker, _gate(), interval_s=0.01))  # type: ignore[arg-type]
    try:
        await asyncio.sleep(0.05)
        assert worker.allow_pick_jobs is True
        assert len(captured) == 1

        redis.keys.add(in_progress_key_prefix + "order-a")  # picked up
        await asyncio.sleep(0.05)
        assert worker.allow_pick_jobs is False
    finally:
        task.cancel()


async def test_run_gate_stays_closed_when_redis_errors() -> None:
    class _Broken:
        async def exists(self, key: str) -> int:
            raise ConnectionError("tunnel down")

    worker = _FakeWorker(_Broken())
    task = asyncio.create_task(run_gate(worker, _gate(), interval_s=0.01))  # type: ignore[arg-type]
    await asyncio.sleep(0.05)
    task.cancel()
    assert worker.allow_pick_jobs is False


def test_backup_worker_shares_the_queue_but_not_the_heartbeat_key() -> None:
    # Same queue: it can run any order. Own heartbeat key: the queue's
    # health-check key stays the Fly worker's, which is what the gate and the
    # prod monitor read. Starts closed: nothing is taken before the first check.
    worker = build_worker()
    assert worker.queue_name == default_queue_name
    assert worker.health_check_key == BACKUP_HEALTH_CHECK_KEY
    assert worker.health_check_key != FLY_KEY
    assert worker.allow_pick_jobs is False
