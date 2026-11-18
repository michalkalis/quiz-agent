"""Lazy recap snapshots (#213.3).

Nothing schedules these: ``GET /me/recaps`` calls :func:`ensure_recaps`, which
creates any recap the player has earned and not got yet. A snapshot is inserted
once (``ON CONFLICT DO NOTHING``) and never recomputed, so a recap does not
change later when thresholds, formulas or the underlying events do.
"""

from __future__ import annotations

from datetime import date, datetime, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from ..db.models import AnalyticsEvent, PlayerRecap
from . import queries
from .config import RECAP_SCHEMA_VERSION
from .config import THRESHOLDS as T
from .player_type import player_type
from .service import compute_player_stats


async def player_timezone(session: AsyncSession, ids: list[str]) -> ZoneInfo:
    """Zone of the player's most recent game, else UTC."""
    name = (
        await session.execute(
            select(AnalyticsEvent.properties["timezone"].astext)
            .where(
                AnalyticsEvent.name == "quiz_context",
                AnalyticsEvent.subject_id.in_(ids),
                AnalyticsEvent.properties["timezone"].astext.is_not(None),
            )
            .order_by(AnalyticsEvent.occurred_at.desc())
            .limit(1)
        )
    ).scalar()
    try:
        return ZoneInfo(name) if name else ZoneInfo("UTC")
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo("UTC")


def _utc(day: date, zone: ZoneInfo) -> datetime:
    """Local midnight of ``day`` as an instant."""
    return datetime(day.year, day.month, day.day, tzinfo=zone).astimezone(timezone.utc)


async def _snapshot(
    session: AsyncSession,
    ids: list[str],
    zone: ZoneInfo,
    start: datetime | None,
    end: datetime | None,
) -> tuple[dict, int, int]:
    """(payload, answers, game days) of the window."""
    stats = await compute_player_stats(
        session, ids, start=start, end=end, fallback_tz=zone.key
    )
    progress = stats["first_recap_progress"]
    unlocked = [c for c in stats["cards"] if c["state"] == "unlocked"]
    latency = await queries.fetch_latency_overall(session, ids, start, end)
    totals = next(c["data"] for c in unlocked if c["kind"] == "totals")
    payload = {
        "cards": unlocked,
        "player_type": player_type({c["kind"]: c for c in stats["cards"]}, latency),
        "summary": totals,
        "timezone": zone.key,
    }
    return payload, progress["answers"], progress["days"]


async def _insert(
    session: AsyncSession, caller_id: str, kind: str, period: date, payload: dict
) -> None:
    await session.execute(
        pg_insert(PlayerRecap)
        .values(
            subject_id=caller_id,
            kind=kind,
            period_start=period,
            payload=payload,
            schema_version=RECAP_SCHEMA_VERSION,
            created_at=datetime.now(timezone.utc),
        )
        .on_conflict_do_nothing(constraint="uq_player_recaps_period")
    )


async def ensure_recaps(
    session: AsyncSession, caller_id: str, ids: list[str], now: datetime
) -> None:
    """Create the recaps the player has earned and no identity of theirs has.

    Only the immediately previous month is considered (no backfill). The caller
    commits."""
    zone = await player_timezone(session, ids)
    today = now.astimezone(zone).date()
    have = set(
        (
            await session.execute(
                select(PlayerRecap.kind, PlayerRecap.period_start).where(
                    PlayerRecap.subject_id.in_(ids)
                )
            )
        ).all()
    )

    this_month = today.replace(day=1)
    prev_month = (
        date(this_month.year - 1, 12, 1)
        if this_month.month == 1
        else date(this_month.year, this_month.month - 1, 1)
    )
    if ("month", prev_month) not in have:
        payload, answers, days = await _snapshot(
            session, ids, zone, _utc(prev_month, zone), _utc(this_month, zone)
        )
        if answers >= T["month_recap_answers"] and days >= T["month_recap_days"]:
            await _insert(session, caller_id, "month", prev_month, payload)

    year_start = date(today.year, 1, 1)
    if today.month == 12 and ("year", year_start) not in have:
        payload, answers, _ = await _snapshot(
            session,
            ids,
            zone,
            _utc(year_start, zone),
            _utc(date(today.year, 12, 1), zone),
        )
        if answers >= T["year_recap_answers"]:
            await _insert(session, caller_id, "year", year_start, payload)

    if not any(kind == "first" for kind, _ in have):
        payload, answers, days = await _snapshot(session, ids, zone, None, None)
        if answers >= T["first_recap_answers"] and days >= T["first_recap_days"]:
            await _insert(session, caller_id, "first", today, payload)
