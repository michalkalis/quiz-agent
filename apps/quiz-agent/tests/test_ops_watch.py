"""Infrastructure + latency watch (#207 — production readiness, 207.8/207.9).

Why these matter: the watch is the early warning for slow-burn outages (a
full DB volume, exhausted connections, a backend that got slow). It is only
useful if
- it alarms on the right side of each threshold, per prod app, and ignores
  staging and the Fly builder (their numbers are not production);
- one condition that lasts for hours is one alert per 6 h, not one per 5-min
  run (5k Sentry events/month on our plan), and re-alerts after recovery;
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


def _reading(alarm: bool, value: float = 75.0) -> ow.Reading:
    return ow.Reading(
        kind="disk", target="quiz-pack-db/m1", value=value, threshold=70, alarm=alarm
    )


@pytest.fixture
def captured(monkeypatch) -> list[tuple[str, list[str]]]:
    calls: list[tuple[str, list[str]]] = []
    monkeypatch.setattr(
        ow.sentry_sdk,
        "capture_message",
        lambda msg, **kw: calls.append((msg, kw["fingerprint"])),
    )
    return calls


async def test_lasting_alarm_is_throttled_and_realerts_after_recovery(captured):
    w = ow.OpsWatch()
    w.report([_reading(True)], [], now=0)
    w.report([_reading(True)], [], now=300)  # next run, same condition
    assert len(captured) == 1
    assert captured[0][1] == ["ops-watch", "disk", "quiz-pack-db"]
    assert "75%" in captured[0][0] and "70%" in captured[0][0]
    w.report([_reading(True)], [], now=ow.REALERT_S + 1)
    assert len(captured) == 2
    w.report([_reading(False, 40)], [], now=ow.REALERT_S + 301)  # recovered
    w.report([_reading(True)], [], now=ow.REALERT_S + 601)  # back again
    assert len(captured) == 3


async def test_blind_watch_reports_only_after_consecutive_failures(captured):
    w = ow.OpsWatch()
    w.report([], ["fly disk (HTTPStatusError)"], now=0)
    w.report([], [], now=300)  # healed: counter resets
    for i in range(ow.BLIND_AFTER_RUNS):
        w.report([], ["fly disk (HTTPStatusError)"], now=600 + i * 300)
    assert [fp for _, fp in captured] == [["ops-watch", "blind"]]


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
