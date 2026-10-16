"""Operational alerts by e-mail (#207 — production readiness).

Founder 2026-10-16: an outage, a credit running out or a full disk must reach
him within minutes, without a new external service. The servers e-mail him
themselves through the Trubbo mail setup (Resend SMTP, sender on the verified
trubbo.app domain) to ``ALERT_EMAIL_TO``.

``AlertBook`` dedupes: one mail when a problem appears or changes state
(low → critical), one recovery mail when it clears, nothing while it stays the
same. With a state file (quiz-agent keeps it on its /data volume) a deploy or
restart does not re-send ongoing problems; without one (the pack worker) a
restart re-sends at most once. A mail that fails to send is not recorded, so
the next check tries again.

Config (env): ``ALERT_SMTP_PASSWORD`` (Resend SMTP key, sending only),
``ALERT_EMAIL_TO``, optional ``ALERT_EMAIL_FROM``. Missing → alerts are only
logged (local dev and tests send nothing).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import smtplib
import socket
import time
from collections.abc import Awaitable, Callable
from email.message import EmailMessage
from pathlib import Path

logger = logging.getLogger(__name__)

SMTP_HOST = "smtp.resend.com"
SMTP_PORT = 465
SMTP_USER = "resend"
DEFAULT_FROM = "Trubbo monitor <monitor@trubbo.app>"


def mail_configured() -> bool:
    return bool(os.getenv("ALERT_SMTP_PASSWORD") and os.getenv("ALERT_EMAIL_TO"))


def send_email(subject: str, body: str) -> bool:
    """Send one plain-text mail; False (logged) when unconfigured or failing.
    Never raises and never logs the password."""
    password = os.getenv("ALERT_SMTP_PASSWORD")
    to = os.getenv("ALERT_EMAIL_TO")
    if not (password and to):
        logger.warning("ALERT (mail not configured): %s", subject)
        return False
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = os.getenv("ALERT_EMAIL_FROM") or DEFAULT_FROM
    msg["To"] = to
    msg.set_content(body)
    try:
        with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, timeout=20) as smtp:
            smtp.login(SMTP_USER, password)
            smtp.send_message(msg)
    except Exception as exc:  # noqa: BLE001 — alerting must never crash a caller
        logger.warning("Alert mail failed (%s): %s", type(exc).__name__, subject)
        return False
    logger.info("Alert mail sent: %s", subject)
    return True


async def send_email_async(subject: str, body: str) -> bool:
    return await asyncio.to_thread(send_email, subject, body)


Sender = Callable[[str, str], Awaitable[bool]]


class AlertBook:
    """Problem state per key → mails only on change (see module docstring)."""

    def __init__(
        self,
        source: str,
        state_path: Path | None = None,
        sender: Sender = send_email_async,
    ) -> None:
        self.source = source
        self._path = state_path
        self._send = sender
        self._open: dict[str, dict] = self._load()

    def _load(self) -> dict[str, dict]:
        if self._path is None:
            return {}
        try:
            return json.loads(self._path.read_text())
        except (OSError, ValueError):
            return {}

    def _save(self) -> None:
        if self._path is None:
            return
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            self._path.write_text(json.dumps(self._open))
        except OSError:
            logger.warning("Alert state not saved to %s", self._path, exc_info=True)

    @property
    def open_problems(self) -> dict[str, dict]:
        return dict(self._open)

    def _body(self, detail: str, since: float) -> str:
        started = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(since))
        return (
            f"{detail}\n\nSince: {started}\nReported by: {self.source} "
            f"({socket.gethostname()})\nRunbook: docs/issues/"
            "issue-207-production-readiness.md (section C)\n"
        )

    async def update(
        self,
        key: str,
        state: str | None,
        detail: str = "",
        *,
        notify_recovery: bool = True,
    ) -> None:
        """``state`` None = healthy. Mails on a new or changed state and on
        recovery; a failed send leaves the book unchanged so it retries."""
        prev = self._open.get(key)
        if state is None:
            if prev is None:
                return
            if notify_recovery:
                ok = await self._send(
                    f"[Trubbo OK] {key} recovered",
                    self._body(
                        f"{key} is back to normal. {detail}".strip(), prev["since"]
                    ),
                )
                if not ok and mail_configured():
                    return
            self._open.pop(key)
            self._save()
            return
        if prev is not None and prev["state"] == state:
            return
        since = prev["since"] if prev else time.time()
        ok = await self._send(
            f"[Trubbo ALERT] {key}: {state}", self._body(detail, since)
        )
        if not ok and mail_configured():
            return
        self._open[key] = {"state": state, "since": since, "detail": detail}
        self._save()
