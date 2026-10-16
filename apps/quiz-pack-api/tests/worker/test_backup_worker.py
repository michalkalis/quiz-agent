"""mba backup worker (#207 207.5 — Fly worker primary, mba only a backup).

Founder 2026-10-16: paid packs run on the Fly worker (Anthropic API); the mba
session worker may take an order only when the Fly worker is gone or an order
sits unclaimed. These tests pin the two ways that could go wrong: the backup
stepping in while Fly copes (a deploy restart, a long pack run on Fly), and
the backup staying out while an order is stranded.

Founder 2026-10-16: the backup runs on the founder's Claude subscription, so it
may generate only beta-testing (StoreKit Sandbox / TestFlight) orders. A paying
App Store customer's order must never be generated on the subscription, so the
last block pins that the backup never claims one, even with Fly down.
"""

from __future__ import annotations

import asyncio
import uuid
from contextlib import asynccontextmanager
from typing import Any

import pytest
from app.config import BACKUP_HEALTH_CHECK_KEY
from app.worker import backup
from app.worker.backup import BackupGate, BetaOrdersOnly, build_worker, run_gate
from arq.constants import default_queue_name, in_progress_key_prefix
from arq.worker import Worker

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


async def _any_order(job_id: str) -> bool:
    return True


def _gate(clock: _Clock | None = None, eligible=_any_order) -> BackupGate:
    return BackupGate(
        default_queue_name,
        fly_down_grace_s=GRACE_S,
        queue_wait_s=WAIT_S,
        eligible=eligible,
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
    worker = build_worker(eligible=_any_order)
    assert worker.queue_name == default_queue_name
    assert worker.health_check_key == BACKUP_HEALTH_CHECK_KEY
    assert worker.health_check_key != FLY_KEY
    assert worker.allow_pick_jobs is False


# --- beta (Sandbox) orders only -------------------------------------------

SANDBOX_ORDER = uuid.uuid4()
APP_STORE_ORDER = uuid.uuid4()
UNKNOWN_ORDER = uuid.uuid4()  # pre-#207 row or admin-key order: NULL
MISSING_ORDER = uuid.uuid4()
ENVIRONMENTS = {SANDBOX_ORDER: "Sandbox", APP_STORE_ORDER: "Production", UNKNOWN_ORDER: None}


def _job(order_id: uuid.UUID, attempt: int = 0) -> str:
    return f"process_order:{order_id}:{attempt}"


class _FakeResult:
    def __init__(self, value: Any) -> None:
        self.value = value

    def scalar_one_or_none(self) -> Any:
        return self.value


class _FakeSession:
    def __init__(self, lookups: list[uuid.UUID], fail: bool) -> None:
        self.lookups = lookups
        self.fail = fail

    async def execute(self, stmt: Any) -> _FakeResult:
        if self.fail:
            raise ConnectionError("db down")
        order_id = stmt.whereclause.right.value
        self.lookups.append(order_id)
        return _FakeResult(ENVIRONMENTS.get(order_id))


def _beta_only(fail: bool = False) -> tuple[BetaOrdersOnly, list[uuid.UUID]]:
    lookups: list[uuid.UUID] = []

    @asynccontextmanager
    async def factory():
        yield _FakeSession(lookups, fail)

    return BetaOrdersOnly(session_factory=factory), lookups


async def test_backup_may_generate_a_testflight_order() -> None:
    eligible, _ = _beta_only()
    assert await eligible(_job(SANDBOX_ORDER)) is True


async def test_backup_never_generates_an_app_store_customers_order() -> None:
    # The subscription is the founder's, not a production resource: a paying
    # customer's pack waits for the Fly worker (or the refund path) instead.
    eligible, _ = _beta_only()
    assert await eligible(_job(APP_STORE_ORDER)) is False
    assert await eligible(_job(APP_STORE_ORDER, attempt=3)) is False


@pytest.mark.parametrize(
    "job_id",
    [_job(UNKNOWN_ORDER), _job(MISSING_ORDER), "process_order:not-a-uuid:0", "something-else"],
)
async def test_an_order_it_cannot_place_in_the_sandbox_is_refused(job_id: str) -> None:
    # Fail closed: "unknown" could be an App Store customer.
    eligible, _ = _beta_only()
    assert await eligible(job_id) is False


async def test_a_database_error_refuses_instead_of_guessing() -> None:
    eligible, _ = _beta_only(fail=True)
    assert await eligible(_job(SANDBOX_ORDER)) is False


async def test_the_environment_is_looked_up_once_per_order() -> None:
    # ARQ polls about twice a second; an immutable fact needs one query.
    eligible, lookups = _beta_only()
    for _ in range(3):
        await eligible(_job(APP_STORE_ORDER))
        await eligible(_job(SANDBOX_ORDER))
    assert sorted(map(str, lookups)) == sorted([str(APP_STORE_ORDER), str(SANDBOX_ORDER)])


async def test_backup_worker_does_not_claim_app_store_orders_with_fly_down(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The gate is open (Fly down). The refused order is never handed to ARQ's
    # claim, so it stays in the queue untouched for the Fly worker; the sweep
    # cron still runs (it only re-enqueues, never generates).
    claimed: list[list[bytes]] = []

    async def fake_start_jobs(self: Worker, job_ids: list[bytes]) -> None:
        claimed.append(job_ids)

    monkeypatch.setattr(Worker, "start_jobs", fake_start_jobs)
    eligible, _ = _beta_only()
    worker = build_worker(eligible=eligible)
    queued = [
        _job(APP_STORE_ORDER).encode(),
        _job(SANDBOX_ORDER).encode(),
        _job(UNKNOWN_ORDER).encode(),
        b"cron:sweep_stuck_orders:1",
    ]
    await worker.start_jobs(queued)
    assert claimed == [[_job(SANDBOX_ORDER).encode(), b"cron:sweep_stuck_orders:1"]]


async def test_a_waiting_app_store_order_does_not_open_the_gate() -> None:
    # Fly alive but an App Store order sits unclaimed: the backup could not
    # take it anyway, so it must not "take over" (and page) for it.
    eligible, _ = _beta_only()
    redis = _FakeRedis(
        keys={FLY_KEY}, queue={_job(APP_STORE_ORDER): NOW_MS - (WAIT_S + 60) * 1000}
    )
    assert await _gate(eligible=eligible).reason_to_take_over(redis) is None
