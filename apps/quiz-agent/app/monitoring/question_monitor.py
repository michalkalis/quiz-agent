"""Question database health monitor.

Checks question inventory levels and alerts when thresholds are breached.
"""

import os
import json
from datetime import datetime, timezone
from dataclasses import dataclass, field
from typing import Optional

import chromadb


@dataclass
class HealthStatus:
    """Question database health status."""

    total_approved: int = 0
    total_pending: int = 0
    total_expired: int = 0
    by_difficulty: dict[str, int] = field(default_factory=dict)
    by_topic: dict[str, int] = field(default_factory=dict)
    avg_daily_usage: float = 0.0
    runway_days: float = 0.0  # estimated days before running out
    alerts: list[str] = field(default_factory=list)
    checked_at: str = ""

    @property
    def level(self) -> str:
        """Overall health level: ok, warning, critical."""
        if any("CRITICAL" in a for a in self.alerts):
            return "critical"
        if any("WARNING" in a for a in self.alerts):
            return "warning"
        return "ok"

    def to_dict(self) -> dict:
        return {
            "level": self.level,
            "total_approved": self.total_approved,
            "total_pending": self.total_pending,
            "total_expired": self.total_expired,
            "by_difficulty": self.by_difficulty,
            "by_topic": self.by_topic,
            "avg_daily_usage": self.avg_daily_usage,
            "runway_days": self.runway_days,
            "alerts": self.alerts,
            "checked_at": self.checked_at,
        }


# Thresholds
CRITICAL_TOTAL = 20
WARNING_PER_DIFFICULTY = 5
LOW_RUNWAY_DAYS = 14


class QuestionMonitor:
    """Monitors question database health."""

    def __init__(self, chroma_client: Optional[chromadb.ClientAPI] = None, chroma_path: Optional[str] = None):
        if chroma_client:
            self.chroma = chroma_client
        else:
            path = chroma_path or os.environ.get(
                "CHROMA_PATH",
                os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "chroma_data"),
            )
            self.chroma = chromadb.PersistentClient(path=path)

        try:
            self.collection = self.chroma.get_collection("quiz_questions")
        except Exception:
            self.collection = None

    def check_health(self) -> HealthStatus:
        """Run all health checks and return status."""
        status = HealthStatus(checked_at=datetime.now(timezone.utc).isoformat())

        if not self.collection:
            status.alerts.append("CRITICAL: No quiz_questions collection found in ChromaDB")
            return status

        # Get all questions with metadata
        try:
            result = self.collection.get(include=["metadatas"])
        except Exception as e:
            status.alerts.append(f"CRITICAL: Failed to query ChromaDB: {e}")
            return status

        metadatas = result.get("metadatas", [])

        if not metadatas:
            status.alerts.append("CRITICAL: No questions in database")
            return status

        # Count by status
        for meta in metadatas:
            review_status = meta.get("review_status", "unknown")
            if review_status == "approved":
                status.total_approved += 1

                # Count by difficulty
                diff = meta.get("difficulty", "unknown")
                status.by_difficulty[diff] = status.by_difficulty.get(diff, 0) + 1

                # Count by topic
                topic = meta.get("topic", "unknown")
                status.by_topic[topic] = status.by_topic.get(topic, 0) + 1

                # Count expired
                expires_at = meta.get("expires_at")
                if expires_at:
                    try:
                        exp_date = datetime.fromisoformat(expires_at)
                        if exp_date < datetime.now(timezone.utc):
                            status.total_expired += 1
                    except (ValueError, TypeError):
                        pass

            elif review_status == "pending_review":
                status.total_pending += 1

        # Estimate usage rate (rough: assume 10 questions/user/day, estimate from usage_count)
        total_usage = sum(meta.get("usage_count", 0) for meta in metadatas)
        # Simple estimate: total usage over ~30 days
        status.avg_daily_usage = total_usage / 30 if total_usage > 0 else 5.0  # assume 5/day minimum

        # Calculate runway
        active_approved = status.total_approved - status.total_expired
        if status.avg_daily_usage > 0 and active_approved > 0:
            status.runway_days = active_approved / status.avg_daily_usage

        # Generate alerts
        if active_approved < CRITICAL_TOTAL:
            status.alerts.append(
                f"CRITICAL: Only {active_approved} active approved questions (threshold: {CRITICAL_TOTAL})"
            )

        for diff, count in status.by_difficulty.items():
            if count < WARNING_PER_DIFFICULTY:
                status.alerts.append(
                    f"WARNING: Only {count} approved {diff} questions (threshold: {WARNING_PER_DIFFICULTY})"
                )

        if status.runway_days < LOW_RUNWAY_DAYS and status.runway_days > 0:
            status.alerts.append(
                f"WARNING: Low runway — estimated {status.runway_days:.0f} days of questions remaining (threshold: {LOW_RUNWAY_DAYS})"
            )

        if status.total_pending > 0:
            status.alerts.append(
                f"INFO: {status.total_pending} questions pending review"
            )

        if status.total_expired > 0:
            status.alerts.append(
                f"INFO: {status.total_expired} expired questions still in database"
            )

        return status

    def should_trigger_generation(self) -> tuple[bool, str]:
        """Check if auto-generation should be triggered.

        Returns (should_generate, reason).
        """
        status = self.check_health()

        if status.level == "critical":
            return True, f"Critical: {status.alerts[0]}"

        # Check individual difficulty levels
        for diff in ["easy", "medium", "hard"]:
            count = status.by_difficulty.get(diff, 0)
            if count < WARNING_PER_DIFFICULTY:
                return True, f"Low {diff} questions: {count}"

        if status.runway_days < LOW_RUNWAY_DAYS and status.runway_days > 0:
            return True, f"Low runway: {status.runway_days:.0f} days"

        return False, "All thresholds met"
