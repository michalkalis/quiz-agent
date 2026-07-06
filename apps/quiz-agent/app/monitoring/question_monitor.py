"""Question database health monitor.

Checks question inventory levels and alerts when thresholds are breached.
Reads the canonical pgvector `questions` table (#41 D2); one aggregated
GROUP BY query per health check.
"""

from datetime import datetime, timezone
from dataclasses import dataclass, field

from sqlalchemy import case, func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from quiz_shared.database.pgvector_client import questions_table


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

    def __init__(self, session_factory: async_sessionmaker[AsyncSession]) -> None:
        self._session_factory = session_factory

    async def check_health(self) -> HealthStatus:
        """Run all health checks and return status."""
        status = HealthStatus(checked_at=datetime.now(timezone.utc).isoformat())

        t = questions_table
        now = datetime.now(timezone.utc)
        stmt = select(
            t.c.review_status,
            t.c.difficulty,
            t.c.topic,
            func.count().label("n"),
            func.coalesce(func.sum(t.c.usage_count), 0).label("usage"),
            func.coalesce(
                func.sum(case((t.c.expires_at < now, 1), else_=0)),
                0,
            ).label("expired"),
        ).group_by(t.c.review_status, t.c.difficulty, t.c.topic)

        try:
            async with self._session_factory() as session:
                rows = (await session.execute(stmt)).all()
        except Exception as e:
            status.alerts.append(f"CRITICAL: Failed to query questions table: {e}")
            return status

        if not rows:
            status.alerts.append("CRITICAL: No questions in database")
            return status

        total_usage = 0
        for review_status, difficulty, topic, n, usage, expired in rows:
            total_usage += int(usage)
            if review_status == "approved":
                status.total_approved += n
                diff = difficulty or "unknown"
                status.by_difficulty[diff] = status.by_difficulty.get(diff, 0) + n
                top = topic or "unknown"
                status.by_topic[top] = status.by_topic.get(top, 0) + n
                status.total_expired += int(expired)
            elif review_status == "pending_review":
                status.total_pending += n

        # Estimate usage rate (rough: assume 10 questions/user/day, estimate from usage_count)
        # Simple estimate: total usage over ~30 days
        status.avg_daily_usage = (
            total_usage / 30 if total_usage > 0 else 5.0
        )  # assume 5/day minimum

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
