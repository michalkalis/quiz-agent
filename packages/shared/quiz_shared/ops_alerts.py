"""Operational alerts by e-mail (#207 — production readiness).

Founder 2026-10-16: an outage, a credit running out or a full disk must reach
him within minutes, without a new external service. The servers e-mail him
themselves through the Trubbo mail setup (Resend SMTP, sender on the verified
trubbo.app domain) to ``ALERT_EMAIL_TO``.

Founder 2026-10-16 (evening): mail only when players are affected, now or
soon (live quiz down, paid order stuck, a credit running out, a disk filling).
Problems players never feel (backups, which a self-heal keeps off the disk)
are recorded with ``mail=False``: same state and dedupe, log line only.

``AlertBook`` dedupes: one mail when a problem appears or changes state
(low → critical), one recovery mail when it clears, nothing while it stays the
same. With a durable store (quiz-agent: a Postgres row shared by its machines,
#207.20) or a state file, a deploy or restart does not re-send ongoing
problems; without one (the pack worker) a restart re-sends at most once. A mail that fails to send is not recorded, so
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
from typing import Protocol

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


class AlertStateStore(Protocol):
    """Durable open-problem state shared by several processes."""

    async def load(self) -> dict[str, dict]: ...

    async def save(self, state: dict[str, dict]) -> None: ...


async def _log_only(subject: str, body: str) -> bool:
    logger.warning("Ops (no mail, players not affected): %s", subject)
    return True


class AlertBook:
    """Problem state per key → mails only on change (see module docstring)."""

    def __init__(
        self,
        source: str,
        state_path: Path | None = None,
        sender: Sender = send_email_async,
        store: AlertStateStore | None = None,
    ) -> None:
        self.source = source
        self._path = state_path
        self._send = sender
        self._store = store
        self._open: dict[str, dict] = self._load()

    async def refresh(self) -> None:
        """Re-read the shared store: another machine may have mailed or
        cleared a problem since this one last looked."""
        if self._store is None:
            return
        try:
            self._open = await self._store.load()
        except Exception:  # noqa: BLE001 — keep the last known state
            logger.warning("Alert state not loaded", exc_info=True)

    async def _persist(self) -> None:
        self._save()
        if self._store is None:
            return
        try:
            await self._store.save(self._open)
        except Exception:  # noqa: BLE001 — alerting must never crash a caller
            logger.warning("Alert state not saved", exc_info=True)

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
        mail: bool = True,
    ) -> None:
        """``state`` None = healthy. Mails on a new or changed state and on
        recovery; a failed send leaves the book unchanged so it retries.
        ``mail=False``: players are not affected, so only log it."""
        await self.refresh()
        prev = self._open.get(key)
        send = self._send if mail else _log_only
        if state is None:
            if prev is None:
                return
            if notify_recovery:
                ok = await send(
                    f"[Trubbo OK] {key} recovered",
                    self._body(
                        f"{key} is back to normal. {detail}".strip(), prev["since"]
                    ),
                )
                if not ok and mail_configured():
                    return
            self._open.pop(key)
            await self._persist()
            return
        if prev is not None and prev["state"] == state:
            return
        since = prev["since"] if prev else time.time()
        ok = await send(f"[Trubbo ALERT] {key}: {state}", self._body(detail, since))
        if not ok and mail_configured():
            return
        self._open[key] = {"state": state, "since": since, "detail": detail}
        await self._persist()
