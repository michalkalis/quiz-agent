"""The worker's half of the mutual watch (#207 — production readiness).

Why these matter: when quiz-agent is down, players can't play; when a paid
order goes refund-eligible, a customer paid for nothing. The worker is the
always-on observer that e-mails both within minutes. It is only useful if
- one failed ping (a deploy restart) never mails, 3 in a row do, recovery
  mails once;
- each refund-eligible order mails once (not every 5 minutes);
- the ping carries the shared token (else quiz-agent ignores it and reports
  this worker dead).
"""

from __future__ import annotations

import uuid

import httpx
import pytest
from app.api.v1.admin_orders import AttentionOrder, OrdersAttentionResponse
from app.worker import watch as ww
from quiz_shared.ops_alerts import AlertBook

pytestmark = pytest.mark.asyncio


class _Mails:
    def __init__(self) -> None:
        self.subjects: list[str] = []

    async def __call__(self, subject: str, body: str) -> bool:
        self.subjects.append(subject)
        return True


def _watch() -> tuple[ww.WorkerWatch, _Mails]:
    mails = _Mails()
    return ww.WorkerWatch(AlertBook("t", None, sender=mails)), mails


async def test_quiz_agent_down_mails_after_three_failed_minutes(monkeypatch):
    monkeypatch.setenv("OPS_PING_TOKEN", "tok")
    seen_tokens: list[str] = []
    up = {"ok": False}

    def handler(request: httpx.Request) -> httpx.Response:
        seen_tokens.append(request.headers.get("x-ops-token", ""))
        return httpx.Response(200 if up["ok"] else 502)

    w, mails = _watch()
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as c:
        for _ in range(2):
            await w.ping_quiz_agent(c)
        assert mails.subjects == []  # a restart blip is not an outage
        await w.ping_quiz_agent(c)
        await w.ping_quiz_agent(c)
        assert mails.subjects == ["[Trubbo ALERT] quiz-agent-api: down"]
        up["ok"] = True
        await w.ping_quiz_agent(c)
    assert mails.subjects[-1] == "[Trubbo OK] quiz-agent-api recovered"
    assert set(seen_tokens) == {"tok"}


async def test_refund_eligible_order_mails_once(monkeypatch):
    oid = uuid.uuid4()
    res = OrdersAttentionResponse(
        stuck=[],
        refund_eligible=[
            AttentionOrder(id=oid, status="failed", job_status="failed", idle_minutes=4)
        ],
    )

    async def fake_attention(session, **kw):
        return res

    class _Session:
        async def __aenter__(self):
            return None

        async def __aexit__(self, *a):
            return False

    import app.api.v1.admin_orders as ao
    import app.db.session as db

    monkeypatch.setattr(ao, "orders_needing_attention", fake_attention)
    monkeypatch.setattr(db, "AsyncSessionLocal", lambda: _Session())
    w, mails = _watch()
    await w.check_orders()
    await w.check_orders()
    assert mails.subjects == [f"[Trubbo ALERT] order {str(oid)[:8]}: refund-eligible"]
