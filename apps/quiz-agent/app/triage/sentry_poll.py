"""Sentry → triage: new and returning problems (#218 — crash and feedback automation, 218.3).

Our Sentry plan has no webhooks, so the 5-minute ops loop (leader machine
only) asks Sentry for unresolved production issues, error or worse, sorted by
last activity, and compares them with what was already sent:

- an issue we have not sent with activity since the last poll, or one Sentry
  now marks ``regressed``, → ``sentry_new`` (once);
- new events of an issue already sent → ``sentry_bump``, at most once an hour
  per issue (the triage only updates a counter line, no AI);
- outages (uptime/cron: the alarm mail covers them), feedback and the
  ``feedback.received`` message (the in-app branch sends those) are skipped.

State is one JSON row in ``ops_alert_state`` (source ``triage-sentry``), so a
new leader continues where the old one stopped. Issues silent for 4 days are
forgotten: Sentry auto-resolves after 72 h, so their return is a regression
and arrives as ``sentry_new`` again. The first poll only sets the cursor: no
flood of old problems.
"""

from __future__ import annotations

import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any

import httpx

from .dispatch import dispatch, enabled

logger = logging.getLogger(__name__)

ISSUES_URL = "https://sentry.io/api/0/projects/missinghue/carquiz/issues/"
TOKEN_ENV = "SENTRY_TRIAGE_TOKEN"
STATE_SOURCE = "triage-sentry"
QUERY = "is:unresolved level:[error,fatal]"
ENVIRONMENT = "production"
BUMP_EVERY = timedelta(hours=1)
FORGET_AFTER = timedelta(days=4)
OVERLAP = timedelta(minutes=15)  # Sentry indexes events with a delay
MAX_DISPATCHES_PER_POLL = 10  # a bad build cannot flood the triage at once
_LEVELS = {"error", "fatal"}
_SKIP_CATEGORIES = {"outage", "uptime", "cron", "feedback"}

_warned_no_token = False


def _ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _iso(value: datetime) -> str:
    return value.isoformat()


def relevant(issue: dict[str, Any]) -> bool:
    return (
        issue.get("level") in _LEVELS
        and issue.get("issueCategory") not in _SKIP_CATEGORIES
        and "feedback.received" not in (issue.get("title") or "")
    )


def classify(
    issue: dict[str, Any], record: dict | None, since: datetime, now: datetime
) -> str | None:
    """``sentry_new``, ``sentry_bump`` or None (nothing to send)."""
    last_seen = _ts(issue["lastSeen"])
    if record is None:
        return "sentry_new" if last_seen > since else None
    if issue.get("substatus") == "regressed" and record.get("substatus") != "regressed":
        return "sentry_new"
    if (
        last_seen > _ts(record["reported_seen"])
        and now - _ts(record["sent_at"]) >= BUMP_EVERY
    ):
        return "sentry_bump"
    return None


def issue_payload(issue: dict[str, Any]) -> dict[str, Any]:
    release = issue.get("lastRelease") or issue.get("firstRelease") or {}
    return {
        "id": issue["id"],
        "short_id": issue.get("shortId"),
        "title": (issue.get("title") or "")[:500],
        "level": issue.get("level"),
        "count": issue.get("count"),
        "user_count": issue.get("userCount"),
        "first_seen": issue.get("firstSeen"),
        "last_seen": issue.get("lastSeen"),
        "permalink": issue.get("permalink"),
        "release": release.get("version") if isinstance(release, dict) else None,
    }


async def fetch_issues(client: httpx.AsyncClient, token: str) -> list[dict]:
    r = await client.get(
        ISSUES_URL,
        params={
            "query": QUERY,
            "environment": ENVIRONMENT,
            "sort": "date",
            "limit": 100,
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    r.raise_for_status()
    return r.json()


async def poll(
    store, sessionmaker, client: httpx.AsyncClient, now: datetime | None = None
) -> None:
    """One poll; never raises (failures are warnings, see ``dispatch``)."""
    global _warned_no_token
    token = (os.getenv(TOKEN_ENV) or "").strip()
    if not token:
        if not _warned_no_token:
            logger.info("Triage Sentry poll off: %s not set", TOKEN_ENV)
            _warned_no_token = True
        return
    now = now or datetime.now(timezone.utc)
    try:
        state = await store.load()
        if not await enabled(sessionmaker):
            # Switched off: keep the cursor current, so switching back on
            # does not replay everything that happened in between.
            if state.get("cursor"):
                await store.save({**state, "cursor": _iso(now)})
            return
        if not state.get("cursor"):
            await store.save({"cursor": _iso(now), "issues": {}})
            return
        issues = await fetch_issues(client, token)
    except Exception as e:  # noqa: BLE001 — never an error event (it would loop)
        logger.warning("Triage Sentry poll failed: %r", e)
        return

    since = _ts(state["cursor"]) - OVERLAP
    known: dict[str, dict] = dict(state.get("issues") or {})
    sent = 0
    complete = True
    for issue in reversed(issues):  # oldest activity first
        if not relevant(issue):
            continue
        record = known.get(issue["id"])
        kind = classify(issue, record, since, now)
        if kind is None:
            if record is not None:
                known[issue["id"]] = {
                    **record,
                    "seen": issue["lastSeen"],
                    "substatus": issue.get("substatus"),
                }
            continue
        if sent >= MAX_DISPATCHES_PER_POLL:
            complete = False
            break
        if not await dispatch(kind, issue_payload(issue), sessionmaker, client):
            complete = False  # GitHub down: retry everything next poll
            break
        sent += 1
        known[issue["id"]] = {
            "sent_at": _iso(now),
            "reported_seen": issue["lastSeen"],
            "seen": issue["lastSeen"],
            "substatus": issue.get("substatus"),
        }

    cutoff = now - FORGET_AFTER
    known = {k: v for k, v in known.items() if _ts(v["seen"]) > cutoff}
    cursor = _iso(now) if complete else state["cursor"]
    try:
        await store.save({"cursor": cursor, "issues": known})
    except Exception as e:  # noqa: BLE001
        logger.warning("Triage Sentry state save failed: %r", e)
