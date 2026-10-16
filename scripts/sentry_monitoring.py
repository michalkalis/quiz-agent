#!/usr/bin/env python3
"""Sentry monitors + alert rules as code (#207 — production readiness, 207.7/207.8).

The desired state of every Sentry piece that decides whether an outage reaches
the founder lives here; running the script makes Sentry match it. Dry run by
default (prints what it would change); ``--apply`` writes.

    python3 scripts/sentry_monitoring.py           # plan
    python3 scripts/sentry_monitoring.py --apply   # apply

Token: ``SENTRY_ALERTS_TOKEN`` (needs Alerts: Read & Write + Project: Admin),
read from the environment or the repo-root ``.env``.

Our plan is Sentry Developer (free): 1 uptime monitor, 1 cron monitor, metric
alerts allowed, no paid overage. So:
- the uptime monitor watches quiz-agent-api (the live quiz) every minute;
- the cron monitor ``pack-worker`` is created by the worker's own check-ins
  (apps/quiz-pack-api/app/worker/checkin.py); re-run this script once it
  exists so the alert rule is connected to it;
- one metric alert catches an error spike across all issues;
- one alert rule e-mails the founder for every new or returning problem that
  matters (errors, backend warnings, outages, metric alerts).
Issues auto-resolve after 72 h of silence, so a problem that comes back later
is a "regression" and e-mails again, while a daily repeat of a still-open one
(e.g. a low balance) stays a single e-mail.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

API = "https://sentry.io/api/0"
ORG = "missinghue"
PROJECT = "carquiz"  # iOS app and both backends report into this one project
FOUNDER_USER_ID = "4423159"  # hello@missinghue.com, the org's only member

RESOLVE_AGE_HOURS = 72

UPTIME = {
    "name": "quiz-agent-api health",
    "url": "https://quiz-agent-api.fly.dev/api/v1/health",
    "method": "GET",
    "headers": [],
    "body": None,
    "intervalSeconds": 60,
    "timeoutMs": 10000,
    # 3 failed checks in a row (~3 min) = down; a deploy restart (~20 s) is not.
    "downtimeThreshold": 3,
    "recoveryThreshold": 1,
}

CRON_SLUG = "pack-worker"

ERROR_SPIKE = {
    "name": "Error spike (all errors, 5 min)",
    "type": "metric_issue",
    "dataSources": [
        {
            "queryType": 0,
            "dataset": "events",
            "query": "",
            "aggregate": "count()",
            "timeWindow": 300,
            "environment": None,
            "eventTypes": ["error", "default"],
        }
    ],
    # Normal is 0-8 errors per 5 min (14-day max outside one burst: 13).
    "conditionGroup": {
        "logicType": "any",
        "conditions": [
            {"type": "gt", "comparison": 25, "conditionResult": 75},
            {"type": "lte", "comparison": 25, "conditionResult": 0},
        ],
    },
    "config": {"thresholdPeriod": 1, "detectionType": "static"},
}

ALERT = {
    "name": "Production problem → e-mail founder",
    "enabled": True,
    "environment": None,
    "config": {"frequency": 5},
    "triggers": {
        "logicType": "any-short",
        "conditions": [
            {"type": t, "comparison": True, "conditionResult": True}
            for t in ("first_seen_event", "regression_event", "reappeared_event")
        ],
        "actions": [],
    },
    "actionFilters": [
        {
            # Any one is enough: an error or worse (app crash, backend
            # exception, uptime/cron outage), any backend event (server_name
            # is set only by the Python SDK; backend warnings are our own
            # monitoring signals: low balance, low question stock, slow
            # responses, DB near its limits), or a high-priority issue
            # (metric alerts). iOS warnings (diagnostics) stay quiet.
            "logicType": "any-short",
            "conditions": [
                {
                    "type": "level",
                    "comparison": {"level": 40, "match": "gte"},
                    "conditionResult": True,
                },
                {
                    "type": "tagged_event",
                    "comparison": {"key": "server_name", "match": "is"},
                    "conditionResult": True,
                },
                {
                    "type": "issue_priority_greater_or_equal",
                    "comparison": 75,
                    "conditionResult": True,
                },
                {
                    "type": "issue_category",
                    "comparison": {"value": 10},
                    "conditionResult": True,
                },
            ],
            "actions": [
                {
                    "type": "email",
                    "integrationId": None,
                    "data": {},
                    "config": {
                        "targetType": "user",
                        "targetIdentifier": FOUNDER_USER_ID,
                        "targetDisplay": None,
                    },
                    "status": "active",
                }
            ],
        }
    ],
}


def _token() -> str:
    tok = os.environ.get("SENTRY_ALERTS_TOKEN")
    if tok:
        return tok
    env = Path(__file__).resolve().parents[1] / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            key, _, value = line.partition("=")
            if key.strip().removeprefix("export ") == "SENTRY_ALERTS_TOKEN":
                return value.strip().strip("'\"")
    sys.exit("SENTRY_ALERTS_TOKEN not set (env or repo-root .env)")


def call(method: str, path: str, body: dict | None = None):
    req = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Authorization": f"Bearer {_token()}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        sys.exit(f"{method} {path} → HTTP {exc.code}: {exc.read()[:500]!r}")


def step(apply: bool, what: str, method: str, path: str, body: dict | None = None):
    print(f"{'APPLY' if apply else 'PLAN '} {what}: {method} {path}")
    return call(method, path, body) if apply else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true", help="write the changes")
    apply = parser.parse_args().apply

    project = call("GET", f"/projects/{ORG}/{PROJECT}/")
    if project.get("resolveAge") != RESOLVE_AGE_HOURS:
        step(
            apply,
            f"auto-resolve after {RESOLVE_AGE_HOURS} h",
            "PUT",
            f"/projects/{ORG}/{PROJECT}/",
            {"resolveAge": RESOLVE_AGE_HOURS},
        )

    uptimes = call("GET", f"/organizations/{ORG}/uptime/")
    if uptimes:  # plan allows one; re-point the auto-created one
        u = uptimes[0]
        if any(u.get(k) != v for k, v in UPTIME.items()):
            step(
                apply,
                "uptime monitor",
                "PUT",
                f"/projects/{ORG}/{PROJECT}/uptime/{u['id']}/",
                UPTIME,
            )
    else:
        step(
            apply,
            "uptime monitor",
            "POST",
            f"/projects/{ORG}/{PROJECT}/uptime/",
            UPTIME,
        )

    dets = call(
        "GET", f"/organizations/{ORG}/detectors/?project={project['id']}&per_page=100"
    )
    by_name = {d["name"]: d for d in dets}
    for stale in [d for d in dets if d["name"].startswith("PROBE ")]:
        step(
            apply,
            f"delete probe {stale['name']!r}",
            "DELETE",
            f"/organizations/{ORG}/detectors/{stale['id']}/",
        )
    spike = by_name.get(ERROR_SPIKE["name"])
    if spike is None:
        created = step(
            apply,
            "error-spike metric alert",
            "POST",
            f"/organizations/{ORG}/projects/{PROJECT}/detectors/",
            ERROR_SPIKE,
        )
        if created:
            dets.append(created)
    else:
        step(
            apply,
            "error-spike metric alert",
            "PUT",
            f"/organizations/{ORG}/detectors/{spike['id']}/",
            ERROR_SPIKE,
        )

    # Every detector of the project feeds the alert rule: issue stream (all
    # errors), uptime, the pack-worker cron monitor (once it exists), metrics.
    wanted = [d for d in dets if not d["name"].startswith("PROBE ")]
    if not any(d["type"] == "monitor_check_in_failure" for d in wanted):
        print(
            f"NOTE  cron monitor {CRON_SLUG!r} does not exist yet — it appears with "
            "the worker's first check-in; re-run this script afterwards."
        )
    body = {**ALERT, "detectorIds": sorted({d["id"] for d in wanted})}
    existing = [
        w
        for w in call("GET", f"/organizations/{ORG}/workflows/")
        if w["name"] == ALERT["name"]
    ]
    if existing:
        step(
            apply,
            "alert rule",
            "PUT",
            f"/organizations/{ORG}/workflows/{existing[0]['id']}/",
            body,
        )
    else:
        step(apply, "alert rule", "POST", f"/organizations/{ORG}/workflows/", body)
    print("done" if apply else "dry run — re-run with --apply to write")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
