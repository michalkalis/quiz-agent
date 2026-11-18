"""Sentry gets diagnostics, never what a player typed or said (#207, 207.23).

Three paths could carry player text (answers, transcripts, pack topics,
feedback) into Sentry, and each is closed here once for both backends:

1. Request bodies on error events: the FastAPI integration attaches them by
   default. Off via ``max_request_body_size="never"``, and ``before_send``
   drops any body or cookies an integration attaches anyway.
2. Local variables in stack frames (``user_answer``, ``transcript``,
   ``prompt``): off via ``include_local_variables=False``. Tracebacks keep
   file, line and function.
3. Log lines, which become Sentry Logs, log breadcrumbs and logged errors.
   Player text is logged only through ``user_text_log``, a logger Sentry
   ignores: the line still reaches stdout (Fly logs, minutes of history) for
   live debugging. Every other log line must carry lengths and ids, not text.

``send_default_pii`` stays False: no IP addresses, cookies or auth headers.
"""

from __future__ import annotations

import logging
from typing import Any

USER_TEXT_LOGGER = "quiz.user_text"
user_text_log = logging.getLogger(USER_TEXT_LOGGER)


def strip_request_payload(event: dict[str, Any], hint: Any) -> dict[str, Any]:
    """``before_send``: drop request bodies and cookies from an error event."""
    request = event.get("request")
    if isinstance(request, dict):
        request.pop("data", None)
        request.pop("cookies", None)
    return event


def sentry_privacy_options() -> dict[str, Any]:
    """Keyword arguments for ``sentry_sdk.init``; also tells Sentry to ignore
    ``user_text_log`` (events, breadcrumbs and Sentry Logs)."""
    from sentry_sdk.integrations.logging import (
        ignore_logger,
        ignore_logger_for_sentry_logs,
    )

    ignore_logger(USER_TEXT_LOGGER)
    ignore_logger_for_sentry_logs(USER_TEXT_LOGGER)
    return {
        "send_default_pii": False,
        "max_request_body_size": "never",
        "include_local_variables": False,
        "before_send": strip_request_payload,
    }
