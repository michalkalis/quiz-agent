"""Weekly evaluation of the voice-settings test (#204 task 204.9) — the DB half.

Loads the running rows and the ``answer_captured`` / ``answer_evaluated``
events since the oldest start, hands them to the pure ``decision`` module,
and (unless dry run) writes the decisions back. The result holds aggregates
and decisions only — no ids, no transcripts — because the weekly job prints
it in a public repo.
"""

from __future__ import annotations

from dataclasses import asdict
from datetime import datetime
from typing import Any

from sqlalchemy import select, update

from ..db.base import utcnow
from ..db.models import AnalyticsEvent, VoiceExperimentArm
from .decision import ArmRow, Capture, aggregate, decide, posterior


async def _events(session, name: str, since: datetime) -> list[AnalyticsEvent]:
    stmt = select(AnalyticsEvent).where(
        AnalyticsEvent.name == name, AnalyticsEvent.occurred_at >= since
    )
    return list((await session.execute(stmt)).scalars())


async def evaluate(
    sessionmaker, *, dry_run: bool, now: datetime | None = None
) -> dict[str, Any]:
    now = now or utcnow()
    async with sessionmaker() as session:
        rows = list(
            (
                await session.execute(
                    select(VoiceExperimentArm).where(
                        VoiceExperimentArm.status == "running"
                    )
                )
            ).scalars()
        )
        arms: list[dict[str, Any]] = []
        decisions = []
        captures: list[Capture] = []
        verdicts: dict[tuple[str, str], str] = {}
        if rows:
            since = min(r.started_at for r in rows)
            captures = [
                Capture(e.session_id, e.occurred_at, e.properties or {})
                for e in await _events(session, "answer_captured", since)
            ]
            verdicts = {
                (e.session_id, e.properties.get("question_id")): e.properties.get(
                    "result"
                )
                for e in await _events(session, "answer_evaluated", since)
                if e.session_id and (e.properties or {}).get("question_id")
            }
        for r in sorted(rows, key=lambda r: (r.flag, r.route_group)):
            row = ArmRow(r.flag, r.route_group, r.generation, r.started_at)
            stats = aggregate(captures, row, verdicts)
            post = posterior(stats[True], stats[False])
            decision = decide(row, stats[True], stats[False], post, now)
            arms.append(
                {
                    "flag": r.flag,
                    "route_group": r.route_group,
                    "generation": r.generation,
                    "days_running": (now - r.started_at).days,
                    "on": stats[True].summary(),
                    "off": stats[False].summary(),
                    **post,
                }
            )
            if decision is None:
                continue
            decisions.append(decision)
            if not dry_run:
                # Guarded on status + generation so a row restarted meanwhile
                # is never overwritten by a verdict about its old answers.
                await session.execute(
                    update(VoiceExperimentArm)
                    .where(
                        VoiceExperimentArm.flag == r.flag,
                        VoiceExperimentArm.route_group == r.route_group,
                        VoiceExperimentArm.status == "running",
                        VoiceExperimentArm.generation == r.generation,
                    )
                    .values(
                        status=decision.status,
                        p_on=decision.p_on,
                        decided_at=now,
                        decision_reason=decision.reason,
                        updated_at=now,
                    )
                )
        if not dry_run and decisions:
            await session.commit()
    return {
        "dry_run": dry_run,
        "evaluated_at": now.isoformat(),
        "arms": arms,
        "decisions": [asdict(d) for d in decisions],
    }
