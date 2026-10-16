#!/usr/bin/env python3
"""Second observer on mba (#207 — production readiness, 207.7).

Sentry's uptime monitor (one per plan) watches quiz-agent-api and the pack
worker checks in to a Sentry cron monitor. This watchdog, run every minute by
launchd on mba, is the independent second pair of eyes:

- every run: quiz-agent-api answers /api/v1/health;
- every 15th minute: quiz-pack-api answers /health and no paid custom-pack
  order is stuck or refund-eligible (same admin endpoint as prod-monitor.yml).
  Not every minute: quiz-pack-api scales to zero and each check wakes it.

A check that fails on 3 runs in a row (pack checks: 2) sends one error event
to Sentry (the alert rule e-mails the founder) and a macOS notification; the
event repeats at most hourly while it stays down. Recovery is logged only.

Config: ~/.config/trubbo-watchdog/env (written by install.sh): SENTRY_DSN,
QUIZ_PACK_ADMIN_API_KEY. Stdlib only; never prints secrets.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

HOME = Path(os.environ.get("TRUBBO_WATCHDOG_ROOT") or Path.home())  # override for tests
CONFIG = HOME / ".config/trubbo-watchdog/env"
STATE = HOME / "Library/Application Support/trubbo-watchdog/state.json"
AGENT_HEALTH = "https://quiz-agent-api.fly.dev/api/v1/health"
PACK = "https://quiz-pack-api.fly.dev"
PACK_EVERY_MIN = 15
REALERT_S = 3600


def load_config() -> dict[str, str]:
    cfg = {}
    if CONFIG.exists():
        for line in CONFIG.read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep and not key.startswith("#"):
                cfg[key.strip()] = value.strip().strip("'\"")
    return cfg


def fetch(url: str, timeout: float, headers: dict | None = None) -> bytes:
    req = urllib.request.Request(
        url, headers={"User-Agent": "trubbo-watchdog", **(headers or {})}
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def check_agent(_: dict) -> str | None:
    try:
        fetch(AGENT_HEALTH, 15)
        return None
    except Exception as exc:  # noqa: BLE001
        return f"quiz-agent-api health failed: {type(exc).__name__} {getattr(exc, 'code', '')}"


def check_pack(cfg: dict) -> str | None:
    try:
        fetch(f"{PACK}/health", 60)  # cold start allowed
    except Exception as exc:  # noqa: BLE001
        return f"quiz-pack-api health failed: {type(exc).__name__} {getattr(exc, 'code', '')}"
    key = cfg.get("QUIZ_PACK_ADMIN_API_KEY")
    if not key:
        return "watchdog misconfigured: QUIZ_PACK_ADMIN_API_KEY missing"
    try:
        body = json.loads(
            fetch(
                f"{PACK}/api/v1/admin/orders/attention?stuck_minutes=30&refund_lookback_minutes=120",
                60,
                {"X-Admin-Key": key},
            )
        )
    except Exception as exc:  # noqa: BLE001
        return f"orders attention check failed: {type(exc).__name__} {getattr(exc, 'code', '')}"
    problems = [
        f"{k} order {o['id'][:8]} ({o['status']})"
        for k in ("stuck", "refund_eligible")
        for o in body.get(k, [])
    ]
    return (
        "custom-pack orders need attention: " + ", ".join(problems)
        if problems
        else None
    )


def send_sentry(dsn: str, check: str, message: str, incident: str = "") -> None:
    """One error event via the DSN's envelope endpoint (no SDK on mba). The
    incident id (start of the failure streak) is in the fingerprint, so each new
    outage is a new Sentry issue and e-mails, even while an older one is still
    open (issues auto-resolve only after 72 h of silence)."""
    u = urllib.parse.urlsplit(dsn)
    project = u.path.strip("/")
    event = {
        "event_id": uuid.uuid4().hex,
        "timestamp": time.time(),
        "platform": "python",
        "level": "error",
        "logger": "mba-watchdog",
        "environment": "production",
        "server_name": "mba-watchdog",
        "message": {"formatted": message},
        "fingerprint": ["mba-watchdog", check, incident],
        "tags": {"watchdog_check": check},
    }
    envelope = b"\n".join(
        json.dumps(x).encode()
        for x in (
            {"event_id": event["event_id"], "dsn": dsn},
            {"type": "event"},
            event,
        )
    )
    req = urllib.request.Request(
        f"{u.scheme}://{u.hostname}/api/{project}/envelope/",
        data=envelope,
        headers={
            "Content-Type": "application/x-sentry-envelope",
            "X-Sentry-Auth": f"Sentry sentry_version=7, sentry_key={u.username}, "
            "sentry_client=trubbo-watchdog/1.0",
        },
    )
    urllib.request.urlopen(req, timeout=15).read()


def notify(message: str) -> None:
    subprocess.run(
        [
            "osascript",
            "-e",
            f'display notification {json.dumps(message)} with title "Trubbo prod"',
        ],
        check=False,
        capture_output=True,
    )


def main() -> int:
    cfg = load_config()
    try:
        state = json.loads(STATE.read_text())
    except (OSError, ValueError):
        state = {}
    now = time.time()
    checks = [("agent", check_agent, 3)]
    # Elapsed time, not clock minutes: launchd runs drift and skip while asleep.
    if (
        now - state.get("pack_checked_at", 0) >= PACK_EVERY_MIN * 60 - 30
        or "--all" in sys.argv
    ):
        state["pack_checked_at"] = now
        checks.append(("pack", check_pack, 2))
    for name, fn, threshold in checks:
        s = state.setdefault(name, {"fails": 0, "alerted_at": 0, "since": 0})
        problem = fn(cfg)
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        if problem is None:
            if s["fails"]:
                print(f"{stamp} {name} recovered after {s['fails']} failed run(s)")
            s.update(fails=0, alerted_at=0, since=0)
            continue
        s["fails"] += 1
        if s["fails"] == 1:
            s["since"] = int(now)
        print(f"{stamp} {name} FAIL #{s['fails']}: {problem}")
        if s["fails"] >= threshold and time.time() - s["alerted_at"] > REALERT_S:
            try:
                send_sentry(cfg["SENTRY_DSN"], name, problem, str(s.get("since", 0)))
                s["alerted_at"] = time.time()
                print(f"{stamp} {name} alert sent to Sentry")
            except Exception as exc:  # noqa: BLE001 — still notify locally
                print(f"{stamp} {name} Sentry send failed: {type(exc).__name__}")
            notify(problem)
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state))
    return 0


if __name__ == "__main__":
    if "--test-alert" in sys.argv:  # proves the Sentry → e-mail path end to end
        send_sentry(
            load_config()["SENTRY_DSN"], "test", "mba watchdog test alert (ignore)"
        )
        print("test alert sent")
        raise SystemExit(0)
    raise SystemExit(main())
