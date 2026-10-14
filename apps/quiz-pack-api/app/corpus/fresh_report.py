"""Reporting for the weekly fresh-entertainment run (#202 task 202.3).

- Sentry Crons check-in ``fresh-topup`` (in_progress → ok / error) so a missed
  or failed scheduled run emails the founder, like the #199 stock alerts. Sent
  only for scheduled runs (``--cron-checkin``): a manual or dry run before the
  founder switches the schedule on must not create a monitor that then reports
  every skipped Wednesday as missed.
- One summary message per run, fingerprinted per ISO week, ``warning`` when
  anything needs a look (pending rows, a skipped or failed language, the cap,
  a low domestic share), else ``info``.
"""

from __future__ import annotations

from datetime import date
from typing import Any

import sentry_sdk
from sentry_sdk.crons import MonitorStatus, capture_checkin

MONITOR_SLUG = "fresh-topup"
MONITOR_CONFIG = {
    "schedule": {"type": "crontab", "value": "0 3 * * 3"},
    "timezone": "UTC",
    # GitHub may start a scheduled run late; a run takes about an hour.
    "checkin_margin": 120,
    "max_runtime": 180,
    "failure_issue_threshold": 1,
    "recovery_threshold": 1,
}
# sk/cs: below this domestic share the week's seeds missed the recipe (~7/10).
MIN_DOMESTIC_SHARE = 0.6


def iso_week(today: date) -> str:
    year, week, _ = today.isocalendar()
    return f"{year}-W{week:02d}"


def checkin_start(enabled: bool) -> str | None:
    if not enabled:
        return None
    return capture_checkin(
        monitor_slug=MONITOR_SLUG,
        status=MonitorStatus.IN_PROGRESS,
        monitor_config=MONITOR_CONFIG,
    )


def checkin_finish(check_in_id: str | None, ok: bool) -> None:
    if check_in_id is None:
        return
    capture_checkin(
        monitor_slug=MONITOR_SLUG,
        check_in_id=check_in_id,
        status=MonitorStatus.OK if ok else MonitorStatus.ERROR,
    )


def warnings_for(summary: dict[str, Any]) -> list[str]:
    """Why this run needs a look; empty = level info."""
    notes: list[str] = []
    if summary.get("cap_hit"):
        notes.append("spend cap hit")
    for lang, entry in summary.get("languages", {}).items():
        status = entry.get("status")
        if status != "done":
            notes.append(f"{lang} {status}: {entry.get('reason')}")
            continue
        if entry.get("pending"):
            notes.append(f"{lang}: {entry['pending']} pending review")
        share = entry.get("domestic_share")
        if share is not None and share < MIN_DOMESTIC_SHARE:
            notes.append(f"{lang}: domestic share {share:.0%}")
    return notes


def summary_level(summary: dict[str, Any]) -> str:
    return "warning" if warnings_for(summary) else "info"


def _title(summary: dict[str, Any]) -> str:
    langs = summary.get("languages", {})
    approved = sum(e.get("approved", 0) for e in langs.values())
    pending = sum(e.get("pending", 0) for e in langs.values())
    mode = " (dry run)" if summary.get("dry_run") else ""
    return (
        f"fresh-topup {summary['iso_week']}{mode}: {approved} approved, "
        f"{pending} pending, ${summary['spent_usd']:.2f}"
    )


def send_summary(summary: dict[str, Any]) -> None:
    """One Sentry message per run (questions stay out: stdout carries them)."""
    context = {
        **{k: v for k, v in summary.items() if k != "languages"},
        "languages": {
            lang: {k: v for k, v in entry.items() if k != "questions"}
            for lang, entry in summary.get("languages", {}).items()
        },
        "warnings": warnings_for(summary),
    }
    with sentry_sdk.new_scope() as scope:
        scope.fingerprint = ["fresh-topup", summary["iso_week"]]
        scope.set_tag("job", "fresh-topup")
        scope.set_context("fresh_topup", context)
        sentry_sdk.capture_message(_title(summary), level=summary_level(summary))
