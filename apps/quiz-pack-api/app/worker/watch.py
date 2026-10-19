"""The pack worker's half of the mutual watch with quiz-agent (#207).

Founder 2026-10-16: outages reach him by e-mail within minutes, no new service.
The always-on primary Fly worker, every minute:
- pings quiz-agent (``POST /api/v1/ops/worker-ping``, shared
  ``OPS_PING_TOKEN``). quiz-agent mails when the pings stop (no worker); this
  side mails when quiz-agent stops answering for 3 minutes in a row, and again
  when it is back;
- every 5 minutes, mails each paid order that turned refund-eligible in the
  last 2 hours, or that is stuck (same query as the admin attention endpoint).

Alert state lives in quiz-agent's ``ops_alert_state`` table (same Postgres,
own row): 207.29, the 2026-10-16 host crash restarted this worker while
quiz-agent was down, the in-memory book forgot the open "down" and the
recovery mail never came. A worker restart now neither re-sends an open
problem nor loses its recovery.

Limit: quiz-agent and this worker both run in Fly region cdg; a region outage
silences both (only the GitHub prod monitor, ~every 4 h, would notice).
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone

import httpx
from quiz_shared.ops_alerts import AlertBook

logger = logging.getLogger(__name__)

FAILS_TO_ALERT = 3
ORDERS_EVERY_TICKS = 5


SOURCE = "pack worker (Fly)"


class WorkerAlertState:
    """``quiz_shared.ops_alerts.AlertStateStore`` on this worker's row of
    quiz-agent's ``ops_alert_state`` table (quiz-agent migration 0016 owns it;
    the same DB). Raw SQL: the model lives in quiz-agent. A failing load/save
    only logs (``AlertBook`` keeps its in-memory state)."""

    def __init__(self, source: str = SOURCE) -> None:
        self._source = source

    async def load(self) -> dict[str, dict]:
        from app.db.session import AsyncSessionLocal
        from sqlalchemy import text

        async with AsyncSessionLocal() as db:
            raw = (
                await db.execute(
                    text("SELECT state_json FROM ops_alert_state WHERE source = :s"),
                    {"s": self._source},
                )
            ).scalar_one_or_none()
        return json.loads(raw) if raw else {}

    async def save(self, state: dict[str, dict]) -> None:
        from app.db.session import AsyncSessionLocal
        from sqlalchemy import text

        async with AsyncSessionLocal() as db:
            await db.execute(
                text(
                    "INSERT INTO ops_alert_state (source, state_json, updated_at) "
                    "VALUES (:s, :j, :t) ON CONFLICT (source) DO UPDATE "
                    "SET state_json = EXCLUDED.state_json, updated_at = EXCLUDED.updated_at"
                ),
                {"s": self._source, "j": json.dumps(state), "t": datetime.now(timezone.utc)},
            )
            await db.commit()


class WorkerWatch:
    def __init__(self, book: AlertBook | None = None) -> None:
        self.book = book or AlertBook(SOURCE, store=WorkerAlertState())
        self.fails = 0
        self.ticks = 0
        self._order_keys: set[str] = set()

    async def tick(self, client: httpx.AsyncClient) -> None:
        await self.ping_quiz_agent(client)
        if self.ticks % ORDERS_EVERY_TICKS == 0:
            await self.check_orders()
        self.ticks += 1

    async def ping_quiz_agent(self, client: httpx.AsyncClient) -> None:
        token = os.getenv("OPS_PING_TOKEN")
        if not token:
            return
        base = os.getenv("QUIZ_AGENT_URL", "https://quiz-agent-api.fly.dev")
        try:
            r = await client.post(
                f"{base}/api/v1/ops/worker-ping",
                headers={"X-Ops-Token": token},
                timeout=15.0,
            )
            r.raise_for_status()
        except Exception as exc:  # noqa: BLE001 — a failed ping is the signal
            self.fails += 1
            logger.warning("quiz-agent ping failed (%s)", type(exc).__name__)
            if self.fails >= FAILS_TO_ALERT:
                await self.book.update(
                    "quiz-agent-api",
                    "down",
                    f"quiz-agent-api did not answer {self.fails} minute checks in a row "
                    f"({type(exc).__name__}): the live quiz is down for players. "
                    "Check: fly status -a quiz-agent-api; fly logs -a quiz-agent-api.",
                )
            return
        self.fails = 0
        await self.book.update("quiz-agent-api", None)

    async def check_orders(self) -> None:
        from app.api.v1.admin_orders import orders_needing_attention
        from app.db.session import AsyncSessionLocal

        try:
            async with AsyncSessionLocal() as session:
                res = await orders_needing_attention(
                    session, stuck_minutes=30, refund_lookback_minutes=120
                )
        except Exception:  # noqa: BLE001 — DB trouble surfaces elsewhere
            logger.warning("orders attention check failed", exc_info=True)
            return
        current: set[str] = set()
        for state, orders in (
            ("stuck", res.stuck),
            ("refund-eligible", res.refund_eligible),
        ):
            for o in orders:
                key = f"order {str(o.id)[:8]}"
                current.add(key)
                await self.book.update(
                    key,
                    state,
                    f"Custom-pack order {o.id} is {state} (status {o.status}, job "
                    f"{o.job_status}, idle {o.idle_minutes} min). A refund-eligible "
                    "order needs a refund or a manual retry (POST /v1/orders/{id}/retry).",
                    notify_recovery=False,
                )
        for key in self._order_keys - current:
            await self.book.update(key, None, notify_recovery=False)
        self._order_keys = current
