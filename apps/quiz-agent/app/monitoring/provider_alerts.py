"""Alert the founder when ElevenLabs refuses TTS or STT (#200).

TF test 2026-10-12: the Slovak voice "read years badly" because the ElevenLabs
API key had hit its own 10,000-credit cap. Every request answered 401
``quota_exceeded``, TTS quietly fell back to OpenAI tts-1 and STT to OpenAI
transcription — the app kept working, so nobody noticed. The daily balance
check (``provider_balances``) could not see it either: it reads the account's
quota, which still had credit left; a per-key cap is not readable with the
key itself (the service-account API-keys endpoint needs ``workspace_read``).

So the refusal itself is the signal: a 401/402/403 from ElevenLabs on the live
TTS or STT path raises a Sentry error (Sentry emails the founder). Transient
failures (5xx, timeouts, 429) stay log-only — the fallback covers them and
they heal on their own. One alert per service+reason per hour per process, so
an outage is one email-worthy issue, not one event per question.
"""

from __future__ import annotations

import json
import logging
import time

import sentry_sdk

logger = logging.getLogger(__name__)

ALERT_INTERVAL_S = 3600.0
# Refusals that will not heal on a retry: exhausted quota, revoked/invalid key,
# missing permission, payment required.
_REFUSAL_STATUSES = frozenset({401, 402, 403})

_last_alert_at: dict[tuple[str, str], float] = {}


def _reason_and_message(status_code: int, body: str) -> tuple[str, str]:
    """ElevenLabs' own ``detail.status`` ("quota_exceeded", "invalid_api_key",
    …) and ``detail.message`` when the body carries them; ``http_<code>`` else."""
    try:
        detail = json.loads(body).get("detail")
    except (ValueError, AttributeError):
        detail = None
    if isinstance(detail, dict):
        reason = str(detail.get("status") or detail.get("code") or "")
        message = str(detail.get("message") or "")
        if reason:
            return reason, message
    return f"http_{status_code}", ""


def report_elevenlabs_refusal(service: str, status_code: int, body: str) -> None:
    """Sentry error for an ElevenLabs quota/auth refusal on ``service``
    ("tts" / "stt"); anything else is not alert-worthy and is ignored."""
    if status_code not in _REFUSAL_STATUSES:
        return
    reason, message = _reason_and_message(status_code, body)
    key = (service, reason)
    now = time.monotonic()
    last = _last_alert_at.get(key)
    if last is not None and now - last < ALERT_INTERVAL_S:
        return
    _last_alert_at[key] = now

    summary = f"ElevenLabs {service.upper()} refused ({reason}, HTTP {status_code})"
    logger.error("%s: %s", summary, message)
    with sentry_sdk.new_scope() as scope:
        # Stable per service+reason: an ongoing outage groups into one issue.
        scope.fingerprint = ["elevenlabs-refused", service, reason]
        scope.set_tag("provider", "elevenlabs")
        scope.set_tag("elevenlabs_service", service)
        scope.set_tag("elevenlabs_reason", reason)
        # ElevenLabs' message only ("This request exceeds your API key quota
        # of 10000…") — never the request, which carries the player's words.
        scope.set_context(
            "elevenlabs", {"status_code": status_code, "message": message[:300]}
        )
        sentry_sdk.capture_message(summary, level="error")
