"""Weekly evaluation of the voice-settings test (#204 task 204.9) — the DB half.

Loads the running rows and the ``answer_captured`` / ``answer_evaluated``
events since the oldest start, hands them to the pure ``decision`` module
(in a worker thread: the Monte Carlo must not stall live quizzes on this
machine), and (unless dry run) writes the decisions back. The result holds
aggregates and decisions only — no ids, no transcripts — because the weekly
job prints it in a public repo.
"""

from __future__ import annotations

import asyncio
from dataclasses import asdict
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import select, update

from ..db.base import utcnow
from ..db.models import AnalyticsEvent, VoiceExperimentArm
from .decision import ArmRow, Capture, score_rows

# Rows decided this recently are reported again (``recent: true``), so a run
# whose response was lost still announces its decision when the job retries.
RECENT = timedelta(hours=1)


async def _events(session, name: str, since: datetime) -> list[AnalyticsEvent]:
    stmt = select(AnalyticsEvent).where(
        AnalyticsEvent.name == name, AnalyticsEvent.occurred_at >= since
    )
    return list((await session.execute(stmt)).scalars())


async def _compute(rows, captures, verdicts, now):
    return await asyncio.to_thread(score_rows, rows, captures, verdicts, now)


def _recent_decisions(all_rows, now: datetime, skip: set) -> list[dict[str, Any]]:
    return [
        {
            "flag": r.flag,
            "route_group": r.route_group,
            "status": r.status,
            "p_on": r.p_on,
            "reason": r.decision_reason,
            "recent": True,
        }
        for r in sorted(all_rows, key=lambda r: (r.flag, r.route_group))
        if r.status != "running"
        and r.decision_reason != "not_applicable"
        and r.decided_at is not None
        and now - r.decided_at <= RECENT
        and (r.flag, r.route_group) not in skip
    ]


async def evaluate(
    sessionmaker, *, dry_run: bool, now: datetime | None = None
) -> dict[str, Any]:
    now = now or utcnow()
    async with sessionmaker() as session:
        all_rows = list((await session.execute(select(VoiceExperimentArm))).scalars())
        running = sorted(
            (r for r in all_rows if r.status == "running"),
            key=lambda r: (r.flag, r.route_group),
        )
        captures: list[Capture] = []
        verdicts: dict[tuple[str, str], str] = {}
        if running:
            since = min(r.started_at for r in running)
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
        rows = [
            ArmRow(r.flag, r.route_group, r.generation, r.started_at) for r in running
        ]
        scored = await _compute(rows, captures, verdicts, now)

        arms: list[dict[str, Any]] = []
        decisions: list[dict[str, Any]] = []
        for row, stats, post, decision in scored:
            arms.append(
                {
                    "flag": row.flag,
                    "route_group": row.route_group,
                    "generation": row.generation,
                    "days_running": (now - row.started_at).days,
                    "on": stats[True].summary(),
                    "off": stats[False].summary(),
                    **post,
                }
            )
            if decision is None:
                continue
            if not dry_run:
                # Guarded on status + generation so a row restarted meanwhile
                # is never overwritten by a verdict about its old answers.
                result = await session.execute(
                    update(VoiceExperimentArm)
                    .where(
                        VoiceExperimentArm.flag == row.flag,
                        VoiceExperimentArm.route_group == row.route_group,
                        VoiceExperimentArm.status == "running",
                        VoiceExperimentArm.generation == row.generation,
                    )
                    .values(
                        status=decision.status,
                        p_on=decision.p_on,
                        decided_at=now,
                        decision_reason=decision.reason,
                        updated_at=now,
                    )
                    # Never patch the loaded rows in memory: they are the
                    # snapshot the "recent" report below must read as loaded.
                    .execution_options(synchronize_session=False)
                )
                if result.rowcount == 0:
                    continue
            decisions.append({**asdict(decision), "recent": False})
        # Read the snapshot before commit (which may expire loaded rows).
        decided_now = {(d["flag"], d["route_group"]) for d in decisions}
        decisions += _recent_decisions(all_rows, now, decided_now)
        if not dry_run and decided_now:
            await session.commit()

    return {
        "dry_run": dry_run,
        "evaluated_at": now.isoformat(),
        "arms": arms,
        "decisions": decisions,
    }
