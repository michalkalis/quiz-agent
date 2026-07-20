"""Centralized logging + Sentry configuration for quiz-pack-api.

Replicates quiz-agent's JSON-structured logging (apps/quiz-agent/app/
logging_config.py) so both backends emit the same log shape, and hosts the
DSN-gated Sentry init (backend arch review 2026-07-18). The API process
(main.py) and the arq worker (worker.on_startup) are separate processes —
each must call both `setup_logging()` and `init_sentry()`.
"""

import logging
import json
import os
import sys
from datetime import datetime, timezone
from typing import Optional

import sentry_sdk


class JSONFormatter(logging.Formatter):
    """JSON log formatter for structured logging."""

    def format(self, record: logging.LogRecord) -> str:
        log_entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        if record.exc_info and record.exc_info[0] is not None:
            log_entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_entry)


def setup_logging() -> None:
    """Configure logging for the application.

    Reads LOG_LEVEL from environment (default: INFO).
    Uses JSON formatting for production, human-readable for development.
    """
    log_level = os.getenv("LOG_LEVEL", "INFO").upper()
    env = os.getenv("ENVIRONMENT", "development")

    root_logger = logging.getLogger()
    root_logger.setLevel(getattr(logging, log_level, logging.INFO))

    # Remove existing handlers to avoid duplicates on reload
    root_logger.handlers.clear()

    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(getattr(logging, log_level, logging.INFO))

    if env == "production":
        handler.setFormatter(JSONFormatter())
    else:
        handler.setFormatter(
            logging.Formatter(
                "%(asctime)s %(levelname)-8s [%(name)s] %(message)s",
                datefmt="%H:%M:%S",
            )
        )

    root_logger.addHandler(handler)

    # Quiet noisy third-party loggers
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("openai").setLevel(logging.WARNING)
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)


def init_sentry(dsn: Optional[str]) -> None:
    """Initialize Sentry — mirrors quiz-agent's DSN-gated init in main.py.

    Unset/empty DSN → clean no-op (dev). SENTRY_DSN comes from settings
    (`Settings.sentry_dsn`), a per-deploy Fly secret.
    """
    if not dsn:
        return
    sentry_sdk.init(
        dsn=dsn,
        traces_sample_rate=0.1,
        environment=os.environ.get("ENVIRONMENT", "development"),
    )
    logging.getLogger(__name__).info(
        "Sentry initialized (env=%s)", os.environ.get("ENVIRONMENT", "development")
    )
