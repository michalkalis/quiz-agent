"""Infrastructure + latency watch (#207 — production readiness, 207.8/207.9).

Every 5 minutes, off the request path, quiz-agent looks at the things that
fail slowly and then all at once, and raises a Sentry issue (the alert rule
e-mails the founder) before they bite:

- disk of every prod Fly volume (Postgres, Redis, quiz-agent's TTS cache):
  the quiz-pack-db volume was 1 GB with no auto-extend;
- memory of every prod Fly machine;
- Postgres connections in use vs ``max_connections`` (shared by both apps);
- quiz-agent's own response time: p95 time-to-first-byte of API requests
  over the last 10 minutes, measured in-process for every request (Sentry
  traces are sampled at 10 % and too sparse at beta traffic).

Fly numbers come from Fly's managed Prometheus with a read-only org token
(``FLY_METRICS_TOKEN``). Disk and connections alarm at 70 %; memory at 90 %
because quiz-agent normally peaks around 72 % (7-day max, 2026-10-16).
Repeated alarms for the same thing are sent at most every 6 h while it lasts;
Sentry groups them into one issue (one e-mail). When the watch itself cannot
read its sources for 3 runs in a row, that is reported too.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from collections import deque

import httpx
import sentry_sdk
from pydantic import BaseModel
from sqlalchemy import text

from ..config import Settings

logger = logging.getLogger(__name__)

_PROMETHEUS = "https://api.fly.io/prometheus/{org}/api/v1/query"
_PROD_APPS = 'app!~".*staging.*|fly-builder.*"'
_DISK_QUERY = (
    f'1 - fly_instance_filesystem_blocks_avail{{mount="/data",{_PROD_APPS}}}'
    f' / fly_instance_filesystem_blocks{{mount="/data",{_PROD_APPS}}}'
)
_MEMORY_QUERY = (
    f"1 - fly_instance_memory_mem_available{{{_PROD_APPS}}}"
    f" / fly_instance_memory_mem_total{{{_PROD_APPS}}}"
)
REALERT_S = 6 * 3600
BLIND_AFTER_RUNS = 3


class Reading(BaseModel):
    kind: str  # disk | memory | db_connections | latency_p95
    target: str  # app (+ instance) or "postgres" / "quiz-agent-api"
    value: float  # percent, or seconds for latency
    threshold: float
    alarm: bool


class LatencyWindow:
    """Time-to-first-byte of recent API requests (bounded memory)."""

    def __init__(self, maxlen: int = 5000) -> None:
        self._samples: deque[tuple[float, float]] = deque(maxlen=maxlen)

    def add(self, seconds: float, now: float | None = None) -> None:
        self._samples.append((time.monotonic() if now is None else now, seconds))

    def p95(self, window_s: float, now: float | None = None) -> tuple[float, int]:
        cutoff = (time.monotonic() if now is None else now) - window_s
        recent = sorted(s for t, s in self._samples if t >= cutoff)
        if not recent:
            return 0.0, 0
        return recent[min(len(recent) - 1, int(len(recent) * 0.95))], len(recent)


latency = LatencyWindow()


class LatencyMiddleware:
    """Pure ASGI (safe for streaming): records time to the response start of
    every /api/ request except the health check."""

    def __init__(self, app) -> None:
        self.app = app

    async def __call__(self, scope, receive, send):
        path = scope.get("path", "") if scope["type"] == "http" else ""
        if not path.startswith("/api/") or path.endswith("/health"):
            await self.app(scope, receive, send)
            return
        start = time.monotonic()

        async def timed_send(message):
            if message["type"] == "http.response.start":
                latency.add(time.monotonic() - start)
            await send(message)

        await self.app(scope, receive, timed_send)


async def _prometheus(
    client: httpx.AsyncClient, s: Settings, token: str, query: str
) -> list[tuple[str, float]]:
    r = await client.get(
        _PROMETHEUS.format(org=s.fly_org),
        params={"query": query},
        headers={"Authorization": token},
    )
    r.raise_for_status()
    out = []
    for row in r.json()["data"]["result"]:
        m = row["metric"]
        out.append((f"{m.get('app')}/{m.get('instance', '?')}", float(row["value"][1])))
    return out


async def collect(
    s: Settings, sessionmaker, client: httpx.AsyncClient
) -> tuple[list[Reading], list[str]]:
    """All readings plus the sources that could not be read (never raises)."""
    readings: list[Reading] = []
    blind: list[str] = []
    token = (os.getenv("FLY_METRICS_TOKEN") or "").strip()
    if token:
        for kind, query, limit in (
            ("disk", _DISK_QUERY, s.ops_disk_alarm_pct),
            ("memory", _MEMORY_QUERY, s.ops_memory_alarm_pct),
        ):
            try:
                for target, frac in await _prometheus(client, s, token, query):
                    pct = round(frac * 100, 1)
                    readings.append(
                        Reading(
                            kind=kind,
                            target=target,
                            value=pct,
                            threshold=limit,
                            alarm=pct >= limit,
                        )
                    )
            except Exception as exc:  # noqa: BLE001 — reported as blind below
                blind.append(f"fly {kind} ({type(exc).__name__})")
    if sessionmaker is not None:
        try:
            async with sessionmaker() as session:
                used, cap = (
                    await session.execute(
                        text(
                            "SELECT (SELECT count(*) FROM pg_stat_activity "
                            "WHERE backend_type = 'client backend'), "
                            "current_setting('max_connections')::int"
                        )
                    )
                ).one()
            pct = round(used / cap * 100, 1)
            limit = s.ops_db_connections_alarm_pct
            readings.append(
                Reading(
                    kind="db_connections",
                    target="postgres",
                    value=pct,
                    threshold=limit,
                    alarm=pct >= limit,
                )
            )
        except Exception as exc:  # noqa: BLE001 — reported as blind below
            blind.append(f"postgres ({type(exc).__name__})")
    p95, n = latency.p95(s.ops_latency_window_s)
    if n >= s.ops_latency_min_requests:
        limit = s.ops_latency_p95_alarm_s
        readings.append(
            Reading(
                kind="latency_p95",
                target="quiz-agent-api",
                value=round(p95, 2),
                threshold=limit,
                alarm=p95 >= limit,
            )
        )
    return readings, blind


class OpsWatch:
    """Turns readings into throttled Sentry issues; keeps the last snapshot."""

    def __init__(self) -> None:
        self.last: list[Reading] = []
        self._alerted_at: dict[tuple[str, str], float] = {}
        # Incident id per condition (wall-clock start) goes into the Sentry
        # fingerprint: a condition that clears and returns is a NEW issue and
        # e-mails again, though issues only auto-resolve after 72 h of silence.
        self._incident: dict[tuple[str, str], str] = {}
        self._blind_runs = 0

    def report(self, readings: list[Reading], blind: list[str], now: float) -> None:
        self.last = readings
        for r in readings:
            key = (r.kind, r.target)
            if not r.alarm:
                self._alerted_at.pop(key, None)
                self._incident.pop(key, None)
                continue
            incident = self._incident.setdefault(key, str(int(time.time())))
            if now - self._alerted_at.get(key, -REALERT_S) < REALERT_S:
                continue
            self._alerted_at[key] = now
            unit = "s" if r.kind == "latency_p95" else "%"
            msg = f"{r.kind} high on {r.target}: {r.value:g}{unit} (alarm at {r.threshold:g}{unit})"
            logger.warning(msg)
            sentry_sdk.capture_message(
                msg,
                level="warning",
                fingerprint=["ops-watch", r.kind, r.target.split("/")[0], incident],
                contexts={"reading": r.model_dump()},
            )
        self._blind_runs = self._blind_runs + 1 if blind else 0
        if self._blind_runs == BLIND_AFTER_RUNS:
            msg = "ops watch cannot read: " + ", ".join(blind)
            logger.warning(msg)
            sentry_sdk.capture_message(
                msg,
                level="warning",
                fingerprint=["ops-watch", "blind", str(int(time.time()))],
            )


watch = OpsWatch()


async def run_ops_watch(s: Settings, sessionmaker) -> None:
    """Background loop: every ``ops_watch_interval_s``, off the request path."""
    async with httpx.AsyncClient(timeout=httpx.Timeout(10.0)) as client:
        while True:
            await asyncio.sleep(s.ops_watch_interval_s)
            try:
                readings, blind = await collect(s, sessionmaker, client)
                watch.report(readings, blind, time.monotonic())
            except Exception:
                logger.exception("Ops watch crashed")
