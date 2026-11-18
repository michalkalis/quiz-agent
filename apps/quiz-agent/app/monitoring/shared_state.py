"""Monitor state shared by every quiz-agent machine (#207.20).

Alert dedupe (was ``/data/ops_alerts.json``) and the pack worker's minute ping
(was in process memory) live in Postgres, so whichever machine runs the
monitors sees what was already mailed and when the worker last pinged —
the ping may land on any machine.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..db.models import OpsAlertState, OpsHeartbeat


class PostgresAlertState:
    """``quiz_shared.ops_alerts.AlertStateStore`` on one ``ops_alert_state`` row."""

    def __init__(self, sm: async_sessionmaker[AsyncSession], source: str) -> None:
        self._sm = sm
        self._source = source

    async def load(self) -> dict[str, dict]:
        async with self._sm() as db:
            raw = (
                await db.execute(
                    select(OpsAlertState.state_json).where(
                        OpsAlertState.source == self._source
                    )
                )
            ).scalar_one_or_none()
        return json.loads(raw) if raw else {}

    async def save(self, state: dict[str, dict]) -> None:
        payload = json.dumps(state)
        stmt = (
            pg_insert(OpsAlertState)
            .values(
                source=self._source,
                state_json=payload,
                updated_at=datetime.now(timezone.utc),
            )
            .on_conflict_do_update(
                index_elements=["source"],
                set_={"state_json": payload, "updated_at": datetime.now(timezone.utc)},
            )
        )
        async with self._sm() as db:
            await db.execute(stmt)
            await db.commit()


class HeartbeatStore:
    def __init__(self, sm: async_sessionmaker[AsyncSession]) -> None:
        self._sm = sm

    async def beat(self, name: str) -> None:
        now = datetime.now(timezone.utc)
        stmt = (
            pg_insert(OpsHeartbeat)
            .values(name=name, seen_at=now)
            .on_conflict_do_update(index_elements=["name"], set_={"seen_at": now})
        )
        async with self._sm() as db:
            await db.execute(stmt)
            await db.commit()

    async def last(self, name: str) -> datetime | None:
        async with self._sm() as db:
            return (
                await db.execute(
                    select(OpsHeartbeat.seen_at).where(OpsHeartbeat.name == name)
                )
            ).scalar_one_or_none()
