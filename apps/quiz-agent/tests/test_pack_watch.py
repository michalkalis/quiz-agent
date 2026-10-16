"""quiz-agent's half of the mutual watch with the pack worker (#207).

Why these matter: when the pack worker dies, paid custom packs silently wait;
the worker's minute pings are how quiz-agent notices within minutes. The
watch is only trustworthy if
- only the worker (shared token) can count as alive — a public caller must
  not be able to mask a dead worker;
- only an outage long enough to keep a paying player waiting mails (30 min):
  a worker deploy or restart is minutes and the mba backup takes orders after
  5 min, so shorter gaps are not news (founder 2026-10-16, evening);
- a fresh ping recovers, but a silent worker is never declared recovered;
- a quiz-agent restart is not mistaken for a dead worker (grace period).
"""

from __future__ import annotations

import pytest
from app.monitoring import pack_watch as pw
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from quiz_shared.ops_alerts import AlertBook

pytestmark = pytest.mark.asyncio


class _Mails:
    def __init__(self) -> None:
        self.subjects: list[str] = []

    async def __call__(self, subject: str, body: str) -> bool:
        self.subjects.append(subject)
        return True


@pytest.fixture
def api(monkeypatch):
    monkeypatch.setenv("OPS_PING_TOKEN", "ping-secret")
    monkeypatch.setattr(pw, "pack_watch", pw.PackWatch(now=0))
    app = FastAPI()
    app.include_router(pw.router, prefix="/api/v1")
    return AsyncClient(transport=ASGITransport(app=app), base_url="http://t")


@pytest.mark.parametrize("headers", [{}, {"X-Ops-Token": "wrong"}])
async def test_ping_without_the_token_does_not_count(api, headers):
    async with api as c:
        r = await c.post("/api/v1/ops/worker-ping", headers=headers)
    assert r.status_code == 401
    assert pw.pack_watch.last_ping is None


async def test_ping_with_token_counts(api):
    async with api as c:
        r = await c.post(
            "/api/v1/ops/worker-ping", headers={"X-Ops-Token": "ping-secret"}
        )
    assert r.status_code == 200
    assert pw.pack_watch.last_ping is not None


async def test_missing_pings_alarm_and_a_ping_recovers(tmp_path, monkeypatch):
    mails = _Mails()
    book = AlertBook("t", tmp_path / "s.json", sender=mails)
    watch = pw.PackWatch(now=0)
    monkeypatch.setattr(pw, "pack_watch", watch)
    await pw.check_worker(book, now=120)  # boot grace: no ping yet is fine
    assert mails.subjects == []
    await pw.check_worker(book, now=600)  # 10 min silent: a deploy, not news
    assert mails.subjects == []
    await pw.check_worker(book, now=1900)  # over 30 min silent
    assert mails.subjects == ["[Trubbo ALERT] pack worker: down"]
    watch.ping(now=1910)
    await pw.check_worker(book, now=1920)
    assert mails.subjects[-1] == "[Trubbo OK] pack worker recovered"


async def test_restart_with_open_alarm_sends_no_false_recovery(tmp_path, monkeypatch):
    """After a deploy the state file still says "down"; the boot grace must
    neither claim recovery nor re-send the alarm."""
    mails = _Mails()
    path = tmp_path / "s.json"
    await AlertBook("t", path, sender=mails).update("pack worker", "down", "no ping")
    book = AlertBook("t", path, sender=mails)
    monkeypatch.setattr(pw, "pack_watch", pw.PackWatch(now=0))
    await pw.check_worker(book, now=60)
    await pw.check_worker(book, now=200)  # still silent, under 30 min
    await pw.check_worker(book, now=1900)
    assert mails.subjects == ["[Trubbo ALERT] pack worker: down"]


async def test_non_ascii_token_is_rejected_not_a_500(api):
    async with api as c:
        r = await c.post(
            "/api/v1/ops/worker-ping", headers={"X-Ops-Token": "\u00e9".encode()}
        )
    assert r.status_code == 401
