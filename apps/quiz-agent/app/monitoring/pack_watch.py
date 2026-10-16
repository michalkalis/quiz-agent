"""quiz-agent's half of the mutual watch with the pack worker (#207).

Founder 2026-10-16: outages must be caught within minutes without a new
service. The always-on Fly pack worker pings quiz-agent every minute
(``POST /api/v1/ops/worker-ping``, shared ``OPS_PING_TOKEN``):
- the worker mails when quiz-agent stops answering (its half, in
  quiz-pack-api ``app/worker/checkin.py``);
- quiz-agent mails when the pings stop, i.e. no primary worker is taking paid
  orders (this half). Missing pings for 3 min = down; the first 3 min after a
  quiz-agent boot never alarm (no ping seen yet is not "worker dead").

quiz-pack-api's web process scales to zero, so it is checked only every
30 min (each check wakes it; ~1 h of machine time a day).

#207.20: the ping may land on any quiz-agent machine, so it is recorded as a
Postgres heartbeat row (``HeartbeatStore``) and the check reads that row.

Limit: both apps run in one Fly region (cdg). A region outage takes both
watchers down with the services; only the GitHub prod monitor (runs every ~4 h)
would notice.
"""

from __future__ import annotations

import asyncio
import hmac
import logging
import os
import time
from datetime import datetime, timezone

import httpx
from fastapi import APIRouter, Header, HTTPException
from quiz_shared.ops_alerts import AlertBook

logger = logging.getLogger(__name__)

PING_STALE_S = 180.0
PACK_API_HEALTH = "https://quiz-pack-api.fly.dev/health"
PACK_API_EVERY_S = 1800.0
PACK_API_FAILS_TO_ALERT = 2
WORKER_HEARTBEAT = "pack worker"


class PackWatch:
    def __init__(self, now: float | None = None) -> None:
        self.started = time.monotonic() if now is None else now
        self.last_ping: float | None = None
        self.pack_api_fails = 0
        # Shared heartbeat row (production); None = this process only (tests).
        self.heartbeats = None

    def ping(self, now: float | None = None) -> None:
        self.last_ping = time.monotonic() if now is None else now

    async def record_ping(self) -> None:
        self.ping()
        if self.heartbeats is not None:
            await self.heartbeats.beat(WORKER_HEARTBEAT)

    async def ping_age(self, now: float) -> float | None:
        """Seconds since the last ping seen by any machine; None = never."""
        if self.heartbeats is not None:
            seen = await self.heartbeats.last(WORKER_HEARTBEAT)
            if seen is None:
                return None
            return (datetime.now(timezone.utc) - seen).total_seconds()
        return None if self.last_ping is None else now - self.last_ping


pack_watch = PackWatch()
router = APIRouter()


@router.post("/ops/worker-ping", include_in_schema=False)
async def worker_ping(x_ops_token: str = Header(default="")) -> dict:
    """The primary pack worker's minute ping (see module docstring)."""
    expected = os.getenv("OPS_PING_TOKEN") or ""
    if not expected or not hmac.compare_digest(x_ops_token.encode(), expected.encode()):
        raise HTTPException(status_code=401)
    await pack_watch.record_ping()
    return {"ok": True}


async def check_worker(book: AlertBook, now: float) -> None:
    age = await pack_watch.ping_age(now)
    since_boot = now - pack_watch.started
    if age is None and since_boot <= PING_STALE_S:
        return  # boot grace: neither "down" nor "recovered" is known yet
    if (age if age is not None else since_boot) > PING_STALE_S:
        await book.update(
            "pack worker",
            "down",
            "No ping from the Fly pack worker for over 3 minutes: paid custom "
            "packs are not being generated (the mba backup takes over after 5 min "
            "if it runs). Check: fly status -a quiz-pack-api (process 'worker').",
        )
    else:
        await book.update("pack worker", None)


async def check_pack_api(client: httpx.AsyncClient, book: AlertBook) -> None:
    try:
        r = await client.get(PACK_API_HEALTH, timeout=60.0)  # cold start allowed
        r.raise_for_status()
        pack_watch.pack_api_fails = 0
        await book.update("quiz-pack-api", None)
    except Exception as exc:  # noqa: BLE001 — a failed check is the signal
        pack_watch.pack_api_fails += 1
        if pack_watch.pack_api_fails >= PACK_API_FAILS_TO_ALERT:
            await book.update(
                "quiz-pack-api",
                "down",
                f"quiz-pack-api /health failed {pack_watch.pack_api_fails}x in a row "
                f"({type(exc).__name__}): nobody can order a custom pack.",
            )


async def run_pack_watch(book: AlertBook) -> None:
    """Every minute: worker pings; every 30 min: quiz-pack-api health."""
    if not os.getenv("OPS_PING_TOKEN"):
        logger.warning("OPS_PING_TOKEN not set: pack worker watch disabled")
        return
    next_pack_check = 0.0
    async with httpx.AsyncClient() as client:
        while True:
            await asyncio.sleep(60)
            now = time.monotonic()
            try:
                await check_worker(book, now)
                if now >= next_pack_check:
                    next_pack_check = now + PACK_API_EVERY_S
                    await check_pack_api(client, book)
            except Exception:
                logger.exception("Pack watch crashed")
