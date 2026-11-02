"""Bridge to the private triage repo (#218 — crash and feedback automation, 218.3).

New Sentry problems, TestFlight feedback/crash reports (App Store Connect
webhook) and in-app feedback become a GitHub ``repository_dispatch`` on
``michalkalis/trubbo-triage``; a workflow there turns each into an issue.
The GitHub token lives only here (``GITHUB_TRIAGE_DISPATCH_TOKEN``).

The bridge never costs a player anything: it runs off the request path, has
a short timeout, and every failure is a warning log (Sentry Logs), never an
error event, which would itself come back through the Sentry poll. Without
the token (staging, laptops) or with the ``triage_bridge_enabled`` switch off
it sends nothing.
"""

from __future__ import annotations

import hashlib
import logging
import os
from typing import Any

import httpx

from .. import app_switches
from ..config import get_settings

logger = logging.getLogger(__name__)

DISPATCH_URL = "https://api.github.com/repos/michalkalis/trubbo-triage/dispatches"
TOKEN_ENV = "GITHUB_TRIAGE_DISPATCH_TOKEN"
TIMEOUT = httpx.Timeout(5.0)
TEXT_MAX_CHARS = 4000  # client_payload stays far below GitHub's size limit

_warned_no_token = False


def _token() -> str:
    return (os.getenv(TOKEN_ENV) or "").strip()


async def enabled(sessionmaker) -> bool:
    """Token configured and the ``triage_bridge_enabled`` switch on."""
    global _warned_no_token
    if not _token():
        if not _warned_no_token:
            logger.info("Triage bridge off: %s not set", TOKEN_ENV)
            _warned_no_token = True
        return False
    overrides = await app_switches.cached_overrides(sessionmaker)
    return app_switches.effective(get_settings(), overrides)["triage_bridge_enabled"]


async def dispatch(
    event_type: str,
    payload: dict[str, Any],
    sessionmaker,
    client: httpx.AsyncClient | None = None,
) -> bool:
    """One ``repository_dispatch``; True when GitHub accepted it. Never raises."""
    try:
        if not await enabled(sessionmaker):
            return False
        request = {
            "url": DISPATCH_URL,
            "json": {"event_type": event_type, "client_payload": payload},
            "headers": {
                "Authorization": f"Bearer {_token()}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        }
        if client is None:
            async with httpx.AsyncClient(timeout=TIMEOUT) as c:
                r = await c.post(**request)
        else:
            r = await client.post(**request, timeout=TIMEOUT)
        if r.status_code != 204:
            logger.warning(
                "Triage dispatch %s refused: HTTP %s", event_type, r.status_code
            )
            return False
        return True
    except Exception as e:  # noqa: BLE001 — the bridge must never break its caller
        logger.warning("Triage dispatch %s failed: %r", event_type, e)
        return False


def anonymous_user(user_id: str | None) -> str | None:
    """Stable, non-reversible id: the triage can count reports per player
    without ever seeing the account id."""
    if not user_id:
        return None
    return hashlib.sha256(f"trubbo-triage:{user_id}".encode()).hexdigest()[:16]


def feedback_payload(row) -> dict[str, Any]:
    """``app_feedback`` client_payload: the content itself, because the triage
    repo holds no admin key. No e-mail, no account id, no attachment bytes."""
    meta = row.metadata_ if isinstance(row.metadata_, dict) else {}
    text = row.message or ""

    def m(key: str) -> str | None:
        value = meta.get(key)
        return str(value) if value is not None else None

    return {
        "id": str(row.id),
        "text": text[:TEXT_MAX_CHARS],
        "text_truncated": len(text) > TEXT_MAX_CHARS,
        "created_at": row.created_at.isoformat() if row.created_at else None,
        "user": anonymous_user(row.user_id),
        "app": {
            "version": row.app_version or m("app_version"),
            "build": m("build"),
            "environment": m("environment"),
        },
        "device": {
            "model": m("device_model"),
            "ios_version": m("ios_version"),
            "locale": m("locale"),
        },
        "quiz": {
            "language": m("quiz_language"),
            "audio_mode": m("audio_mode"),
            "state": m("quiz_state"),
        },
        "attachments": {
            "screenshot": row.screenshot is not None,
            "audio": row.audio is not None,
            "logs": row.logs is not None,
        },
    }


async def dispatch_feedback(row, sessionmaker) -> bool:
    """``app_feedback`` for one saved ``Feedback`` row. Never raises."""
    try:
        payload = feedback_payload(row)
    except Exception as e:  # noqa: BLE001
        logger.warning("Triage feedback payload failed: %r", e)
        return False
    return await dispatch("app_feedback", payload, sessionmaker)
