"""Monitoring off Fly (#222 — Hetzner migration, 222.3).

Why: during the transition the same code runs on Fly (prod today) and on the
Hetzner host. Fly stays the default; the host has no Fly Prometheus, so
- the ops watch must read memory/disk from the host itself and still alarm;
- the pack API health URL must be configurable, with the Fly URL as default;
- the Fly bill check must be silent (never an alert) when no Fly token exists.
"""

from __future__ import annotations

import httpx
import pytest
from app.config import Settings
from app.monitoring import ops_watch as ow
from app.monitoring import pack_watch as pw
from app.monitoring import provider_costs as pc
from httpx import MockTransport, Response

pytestmark = pytest.mark.asyncio


def _local(tmp_path) -> Settings:
    return Settings(ops_metrics_source="local", ops_local_disk_path=str(tmp_path))


async def test_local_source_reads_host_memory_and_never_calls_fly(
    tmp_path, monkeypatch
):
    # A host running out of memory must alarm, labelled as the host, with no
    # token and no call to Fly.
    mem = tmp_path / "meminfo"
    mem.write_text("MemTotal:  1000 kB\nMemFree: 10 kB\nMemAvailable:  50 kB\n")
    monkeypatch.setattr(ow, "_MEMINFO", str(mem))
    monkeypatch.delenv("FLY_METRICS_TOKEN", raising=False)

    def boom(request):
        raise AssertionError("local source must not call Fly")

    async with httpx.AsyncClient(transport=MockTransport(boom)) as c:
        readings, blind = await ow.collect(_local(tmp_path), None, c)
    by_kind = {r.kind: r for r in readings}
    assert by_kind["memory"].target == "hetzner-host"
    assert by_kind["memory"].value == 95.0
    assert by_kind["memory"].alarm  # 95 % >= 90 % threshold
    assert by_kind["disk"].target == "hetzner-host"
    assert blind == []


async def test_local_source_unreadable_is_blind_not_an_exception(tmp_path, monkeypatch):
    monkeypatch.setattr(ow, "_MEMINFO", str(tmp_path / "missing"))
    async with httpx.AsyncClient(transport=MockTransport(lambda r: Response(500))) as c:
        readings, blind = await ow.collect(_local(tmp_path), None, c)
    assert [r.kind for r in readings] == ["disk"]
    assert blind == ["local memory (FileNotFoundError)"]


async def test_default_source_stays_fly(monkeypatch):
    # No new env var, no behaviour change on Fly.
    assert Settings().ops_metrics_source == "fly"
    monkeypatch.delenv("FLY_METRICS_TOKEN", raising=False)
    async with httpx.AsyncClient(transport=MockTransport(lambda r: Response(500))) as c:
        readings, blind = await ow.collect(Settings(), None, c)
    assert readings == [] and blind == []


class _NoBook:
    async def update(self, *a, **k):
        pass


async def test_pack_api_health_url_configurable_with_fly_default(monkeypatch):
    seen: list[str] = []

    def handler(request: httpx.Request) -> Response:
        seen.append(str(request.url))
        return Response(200)

    monkeypatch.delenv("PACK_API_HEALTH_URL", raising=False)
    async with httpx.AsyncClient(transport=MockTransport(handler)) as c:
        await pw.check_pack_api(c, _NoBook())
        monkeypatch.setenv("PACK_API_HEALTH_URL", "http://pack-web:8003/health")
        await pw.check_pack_api(c, _NoBook())
    assert seen == [
        "https://quiz-pack-api.fly.dev/health",
        "http://pack-web:8003/health",
    ]


async def test_fly_bill_without_token_is_unconfigured_never_an_alert(monkeypatch):
    monkeypatch.delenv("FLY_METRICS_TOKEN", raising=False)

    def boom(request):
        raise AssertionError("no Fly call without a token")

    async with httpx.AsyncClient(transport=MockTransport(boom)) as c:
        b = await pc.fly(c, Settings())
    assert b.status == "unconfigured"
