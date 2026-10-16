"""Worker liveness as a Sentry Cron monitor (#207 — production readiness, 207.8).

A dead pack worker is silent: nothing errors, paid orders just wait. Until now
only the GitHub prod monitor asked for the worker's Redis heartbeat, and GitHub
runs that schedule every ~4 h, not every 30 min. Here the worker itself checks
in with Sentry every minute; when check-ins stop for a few minutes Sentry opens
an outage issue and the alert rule e-mails the founder.

Only the primary worker checks in: the Fly worker (paid API, not the
``session`` gateway) consuming the queue orders go to (ORDER_QUEUE_NAME). A
standby on another queue, or the mba session-subscription fallback, must not
mask a dead primary (#207 decision: Fly worker primary, mba backup).
Our Sentry plan has one cron monitor; this is it. The SDK upserts the monitor
from ``MONITOR_CONFIG`` on each check-in, so its schedule lives in code.

It runs as a plain asyncio task in the worker's event loop, not as an arq cron
job: cron jobs need a free job slot, and a worker busy with long packs (the
session worker has one slot for an hour or more) would look dead.
"""

from __future__ import annotations

import asyncio
import logging

import sentry_sdk
from quiz_shared.llm import factory as llm_factory
from sentry_sdk.crons import MonitorStatus, capture_checkin

from app.config import get_settings

logger = logging.getLogger(__name__)

MONITOR_SLUG = "pack-worker"
INTERVAL_S = 60.0
# Missing 3 check-ins in a row (~4 min) opens the issue: a deploy or a
# machine restart (~30-60 s) never pages anyone, a dead worker does quickly.
MONITOR_CONFIG = {
    "schedule": {"type": "interval", "value": 1, "unit": "minute"},
    "checkin_margin": 1,
    "max_runtime": 1,
    "failure_issue_threshold": 3,
    "recovery_threshold": 1,
}


def is_primary() -> bool:
    s = get_settings()
    return (
        s.worker_queue_name == s.order_queue_name
        and llm_factory.gateway() != llm_factory.SESSION
    )


def check_in() -> bool:
    """One OK check-in; False when this worker should not or cannot report."""
    if not is_primary() or sentry_sdk.get_client().dsn is None:
        return False
    try:
        capture_checkin(
            monitor_slug=MONITOR_SLUG,
            status=MonitorStatus.OK,
            monitor_config=MONITOR_CONFIG,
        )
    except Exception:
        logger.warning("Sentry worker check-in failed", exc_info=True)
        return False
    return True


async def _loop() -> None:
    while True:
        check_in()
        await asyncio.sleep(INTERVAL_S)


def start_checkins() -> asyncio.Task[None]:
    """Start the check-in loop on the running loop; it dies with the process."""
    return asyncio.create_task(_loop(), name="sentry-worker-checkin")
