"""Builders for player-stats tests: games as analytics_events rows (#213)."""

from __future__ import annotations

import itertools
from datetime import datetime, timedelta, timezone

from app.db.models import AnalyticsEvent

_n = itertools.count()
UTC = timezone.utc


def at(day: int, hour: int = 12, minute: int = 0, month: int = 10) -> datetime:
    return datetime(2026, month, day, hour, minute, tzinfo=UTC)


def event(name, subject, session, when, source="server", **props) -> AnalyticsEvent:
    return AnalyticsEvent(
        name=name,
        subject_id=subject,
        session_id=session,
        occurred_at=when,
        received_at=when,
        source=source,
        properties=props,
    )


def game(
    subject: str,
    session: str,
    start: datetime,
    answers: list,  # (result, category, difficulty, qtype) or with a 5th item latency_ms
    *,
    tz: str | None = None,
    route: str | None = None,
    context: bool = True,
    step_s: int = 20,
    started: bool = True,
) -> list[AnalyticsEvent]:
    rows = []
    if started:
        rows.append(event("quiz_started", subject, session, start))
    if context:
        props = {k: v for k, v in (("timezone", tz), ("audio_route", route)) if v}
        rows.append(event("quiz_context", subject, session, start, "ios", **props))
    for i, a in enumerate(answers):
        result, cat, diff, qtype, *lat = a
        when = start + timedelta(seconds=step_s * (i + 1))
        qid = f"{session}-q{i}"
        rows.append(
            event(
                "answer_evaluated",
                subject,
                session,
                when,
                question_id=qid,
                result=result,
                category=cat,
                difficulty=diff,
                question_type=qtype,
                is_regrade=False,
            )
        )
        if lat:
            rows.append(
                event(
                    "answer_submitted",
                    subject,
                    session,
                    when,
                    "ios",
                    question_id=qid,
                    is_retry=False,
                    latency_ms=lat[0],
                )
            )
    return rows


def ans(result="correct", cat="science", diff="medium", qtype="text", *lat):
    return (result, cat, diff, qtype, *lat)


async def store(db, rows) -> None:
    async with db() as s:
        s.add_all(rows)
        await s.commit()


def by_kind(stats: dict) -> dict:
    return {c["kind"]: c for c in stats["cards"]}
