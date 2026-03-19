"""In-memory usage tracker for freemium question limits.

Tracks questions-per-day per device (user_id). Resets daily at midnight UTC.
Premium users bypass limits entirely.
"""

import logging
import os
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from threading import Lock
from typing import Dict, Optional, Tuple

logger = logging.getLogger(__name__)

FREE_DAILY_LIMIT = int(os.getenv("FREE_DAILY_LIMIT", "20"))


@dataclass
class UsageRecord:
    user_id: str
    questions_today: int = 0
    last_reset: date = field(default_factory=lambda: datetime.now(timezone.utc).date())
    is_premium: bool = False


class UsageTracker:
    """Tracks daily question usage per user.

    Same pattern as SessionManager — in-memory dict, thread-safe.
    Data resets on server restart, which is fine since daily limits
    reset anyway.
    """

    def __init__(self, daily_limit: int = FREE_DAILY_LIMIT):
        self._records: Dict[str, UsageRecord] = {}
        self._lock = Lock()
        self.daily_limit = daily_limit

    def _get_or_create(self, user_id: str) -> UsageRecord:
        """Get usage record, creating if needed. Resets if new day."""
        today = datetime.now(timezone.utc).date()

        with self._lock:
            record = self._records.get(user_id)
            if not record:
                record = UsageRecord(user_id=user_id, last_reset=today)
                self._records[user_id] = record
            elif record.last_reset < today:
                record.questions_today = 0
                record.last_reset = today
            return record

    def check_limit(self, user_id: str) -> Tuple[bool, int, datetime]:
        """Check if user can ask another question.

        Returns:
            (allowed, remaining, resets_at)
        """
        record = self._get_or_create(user_id)

        if record.is_premium:
            return True, -1, self._next_reset()

        remaining = max(0, self.daily_limit - record.questions_today)
        allowed = remaining > 0
        return allowed, remaining, self._next_reset()

    def record_question(self, user_id: str) -> int:
        """Record a question usage. Returns new count."""
        record = self._get_or_create(user_id)
        if not record.is_premium:
            record.questions_today += 1
            logger.debug(
                "Usage: user=%s questions_today=%d limit=%d",
                user_id, record.questions_today, self.daily_limit,
            )
        return record.questions_today

    def get_usage(self, user_id: str) -> dict:
        """Get usage stats for a user."""
        record = self._get_or_create(user_id)
        resets_at = self._next_reset()

        if record.is_premium:
            return {
                "user_id": user_id,
                "is_premium": True,
                "questions_used": record.questions_today,
                "questions_limit": None,
                "remaining": None,
                "resets_at": resets_at.isoformat(),
            }

        return {
            "user_id": user_id,
            "is_premium": False,
            "questions_used": record.questions_today,
            "questions_limit": self.daily_limit,
            "remaining": max(0, self.daily_limit - record.questions_today),
            "resets_at": resets_at.isoformat(),
        }

    def set_premium(self, user_id: str, is_premium: bool = True):
        """Set premium status for a user."""
        record = self._get_or_create(user_id)
        record.is_premium = is_premium
        logger.info("Premium status: user=%s is_premium=%s", user_id, is_premium)

    def is_premium(self, user_id: str) -> bool:
        """Check if user has premium status."""
        record = self._get_or_create(user_id)
        return record.is_premium

    @staticmethod
    def _next_reset() -> datetime:
        """Get next midnight UTC."""
        now = datetime.now(timezone.utc)
        tomorrow = datetime(
            now.year, now.month, now.day,
            tzinfo=timezone.utc,
        ) + timedelta(days=1)
        return tomorrow
