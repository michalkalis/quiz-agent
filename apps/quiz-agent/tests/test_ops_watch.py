"""Infrastructure + latency watch (#207 — production readiness, 207.8/207.9).

Why these matter: the watch is the early warning for slow-burn outages (a
full DB volume, exhausted connections, a backend that got slow). It is only
useful if
- it alarms on the right side of each threshold, per prod app, and ignores
  staging and the Fly builder (their numbers are not production);
- one condition that lasts for hours is one e-mail, not one per 5-min run;
  recovery is a mail, and a relapse mails again; the worst instance per app
  counts;
- a watch that cannot read its sources says so, but not on a single blip;
- the latency number is a real p95 over the window, and slow health checks or
  old samples never count.
"""

from __future__ import annotations

import httpx
import pytest
from app.config import Settings
from app.monitoring import ops_watch as ow
from httpx import MockTransport, Response
from quiz_shared.ops_alerts import AlertBook

pytestmark = pytest.mark.asyncio

_S = Settings()  # disk/conn 70 %, memory 90 %, p95 8 s over ≥10 requests


def _prom(disk: dict[str, float], mem: dict[str, float], seen: list[str]):
    def handler(request: httpx.Request) -> Response:
        query = request.url.params["query"]
        seen.append(query)
        data = disk if "filesystem" in query else mem
        return Response(
            200,
            json={
                "data": {
                    "result": [
                        {"metric": {"app": app, "instance": "m1"}, "value": [0, str(v)]}
                        for app, v in data.items()
                    ]
                }
            },
        )

    return handler


async def test_disk_and_memory_alarm_per_app_at_their_thresholds(monkeypatch):
    monkeypatch.setenv("FLY_METRICS_TOKEN", "FlyV1 fm2_x")
    seen: list[str] = []
    handler = _prom(
        disk={"quiz-pack-db": 0.72, "quiz-agent-api": 0.10},
        mem={"quiz-agent-api": 0.80, "quiz-pack-redis": 0.95},
        seen=seen,
    )
    async with httpx.AsyncClient(transport=MockTransport(handler)) as c:
        readings, blind = await ow.collect(_S, None, c)
    alarms = {(r.kind, r.target.split("/")[0]) for r in readings if r.alarm}
    # 72 % disk ≥ 70 % alarms; 80 % memory is quiz-agent's normal peak, not 90 %.
    assert alarms == {("disk", "quiz-pack-db"), ("memory", "quiz-pack-redis")}
    assert blind == []
    # Staging apps and the remote builder are excluded in the query itself.
    assert all("staging" in q and "fly-builder" in q for q in seen)


async def test_unreadable_source_is_blind_not_an_exception(monkeypatch):
    monkeypatch.setenv("FLY_METRICS_TOKEN", "FlyV1 fm2_x")
    async with httpx.AsyncClient(transport=MockTransport(lambda r: Response(401))) as c:
        readings, blind = await ow.collect(_S, None, c)
    assert readings == []
    assert len(blind) == 2


def _reading(alarm: bool, value: float = 75.0, instance: str = "m1") -> ow.Reading:
    return ow.Reading(
        kind="disk",
        target=f"quiz-pack-db/{instance}",
        value=value,
        threshold=70,
        alarm=alarm,
    )


class _Mails:
    def __init__(self) -> None:
        self.subjects: list[str] = []

    async def __call__(self, subject: str, body: str) -> bool:
        self.subjects.append(subject)
        return True


@pytest.fixture
def book(tmp_path):
    mails = _Mails()
    return AlertBook("test", tmp_path / "s.json", sender=mails), mails


async def test_lasting_alarm_mails_once_then_recovery_then_relapse(book):
    b, mails = book
    w = ow.OpsWatch()
    await w.report([_reading(True), _reading(False, 10, "m2")], [], b)
    await w.report([_reading(True)], [], b)  # next run, same condition
    assert mails.subjects == ["[Trubbo ALERT] disk quiz-pack-db: high"]
    await w.report([_reading(False, 40)], [], b)
    await w.report([_reading(True)], [], b)
    assert mails.subjects[1:] == [
        "[Trubbo OK] disk quiz-pack-db recovered",
        "[Trubbo ALERT] disk quiz-pack-db: high",
    ]


async def test_blind_watch_reports_only_after_consecutive_failures(book):
    b, mails = book
    w = ow.OpsWatch()
    await w.report([], ["fly disk (HTTPStatusError)"], b)
    await w.report([], [], b)  # healed: counter resets
    for _ in range(ow.BLIND_AFTER_RUNS):
        await w.report([], ["fly disk (HTTPStatusError)"], b)
    assert mails.subjects == ["[Trubbo ALERT] ops watch: blind"]


async def test_latency_p95_needs_enough_recent_requests():
    win = ow.LatencyWindow()
    for i in range(20):
        win.add(0.5 if i < 18 else 12.0, now=1000)
    win.add(60.0, now=0)  # older than the window: ignored
    p95, n = win.p95(600, now=1100)
    assert n == 20
    assert p95 == 12.0  # 2 of 20 slow = above the 95th percentile line


async def test_latency_middleware_times_api_requests_but_not_health():
    from fastapi import FastAPI

    app = FastAPI()

    @app.get("/api/v1/health")
    async def health():
        return {}

    @app.get("/api/v1/thing")
    async def thing():
        return {}

    ow.latency = ow.LatencyWindow()
    wrapped = ow.LatencyMiddleware(app)
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=wrapped), base_url="http://t"
    ) as c:
        await c.get("/api/v1/health")
        await c.get("/api/v1/thing")
    assert ow.latency.p95(600)[1] == 1


async def test_value_hovering_at_the_line_does_not_flap(book):
    """Open alarm at 70 %: 68 % is not a recovery (margin 5), 60 % is."""
    b, mails = book
    w = ow.OpsWatch()
    await w.report([_reading(True, 71)], [], b)
    await w.report([_reading(False, 68)], [], b)
    await w.report([_reading(True, 70)], [], b)
    assert mails.subjects == ["[Trubbo ALERT] disk quiz-pack-db: high"]
    await w.report([_reading(False, 60)], [], b)
    assert mails.subjects[-1] == "[Trubbo OK] disk quiz-pack-db recovered"


class _Budget:
    def __init__(self, day, reached, spent):
        self.value = (day, reached, spent)

    def status(self):
        return self.value


async def test_elevenlabs_budget_hit_mails_once_per_day(book, monkeypatch):
    """Founder wants one mail the day the daily budget is hit (date, credits
    today, monthly remaining) — not one per 5-minute run."""
    from datetime import date

    from app.monitoring import provider_balances as pb

    async def month(client, s):
        return [
            pb.ProviderBalance(
                provider="elevenlabs",
                unit="characters",
                remaining=12000,
                limit=30000,
                status="ok",
            )
        ]

    monkeypatch.setattr(pb, "_elevenlabs", month)
    b, mails = book
    d1 = date(2026, 10, 16)
    await ow.check_elevenlabs_budget(_Budget(d1, False, 3000), _S, None, b)
    assert mails.subjects == []
    for _ in range(3):
        await ow.check_elevenlabs_budget(_Budget(d1, True, 5100), _S, None, b)
    assert mails.subjects == [f"[Trubbo ALERT] elevenlabs daily budget {d1}: reached"]
    await ow.check_elevenlabs_budget(
        _Budget(date(2026, 10, 17), True, 5050), _S, None, b
    )
    assert len(mails.subjects) == 2  # next day, next mail; no recovery mails
