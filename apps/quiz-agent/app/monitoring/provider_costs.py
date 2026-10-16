"""Spend-based provider checks: Anthropic, OpenAI, Fly (#207 — production readiness, 207.12).

``provider_balances`` covers providers that expose a balance to a normal API
key (OpenRouter, ElevenLabs). These three do not, so each is read through an
admin/org credential and turned into the same ``ProviderBalance`` rows:

- Anthropic: the monthly API credit from the Max plan (``ANTHROPIC_CREDIT_USD``
  between ``ANTHROPIC_CREDIT_START`` and ``_EXPIRES``, as ``credit_gate`` uses
  it) minus the organisation's real spend from the Cost API (Admin key).
  Running low or about to expire = warning. Outside a credit period only the
  month's spend is shown: a prepaid balance is not readable by any API.
- OpenAI: this month's spend from the organisation Costs API (Admin key)
  against ``OPENAI_MONTHLY_BUDGET_USD`` — catches runaway use, not a balance.
- Fly: the org's billing status (anything but CURRENT means the card failed
  and apps get suspended) plus a run-rate estimate of the machines that are
  running right now and all volumes, at Fly's list prices.

A missing credential is ``unconfigured`` (shown, never alerted): these keys
are optional and created by the founder. A failed fetch is ``error``.
"""

from __future__ import annotations

import os
from datetime import UTC, date, datetime

import httpx
from quiz_shared.llm.credit_gate import COST_REPORT_URL

from ..config import Settings
from .provider_balances import ProviderBalance, classify, describe_error

_OPENAI_COSTS = "https://api.openai.com/v1/organization/costs"
_FLY_GRAPHQL = "https://api.fly.io/graphql"
_FLY_MACHINES = "https://api.machines.dev/v1"

# Fly list prices (USD/month): a shared vCPU with its first 256 MB, each
# further 256 MB, a performance vCPU with its first 2 GB, a volume GB.
_FLY_SHARED_CPU = 1.94
_FLY_RAM_256MB = 1.25
_FLY_PERF_CPU = 31.0
_FLY_VOLUME_GB = 0.15


def _unconfigured(provider: str, unit: str, detail: str) -> ProviderBalance:
    return ProviderBalance(
        provider=provider, unit=unit, status="unconfigured", detail=detail
    )


def _error(provider: str, unit: str, exc: Exception) -> ProviderBalance:
    return ProviderBalance(
        provider=provider, unit=unit, status="error", detail=describe_error(exc)
    )


def _env_date(name: str) -> date | None:
    raw = (os.getenv(name) or "").strip()
    return date.fromisoformat(raw) if raw else None


async def anthropic_spent_usd(
    client: httpx.AsyncClient, admin_key: str, since: date
) -> float:
    """Organisation spend since ``since`` 00:00 UTC (Cost API, cents → USD)."""
    params: dict[str, object] = {
        "starting_at": datetime(since.year, since.month, since.day, tzinfo=UTC)
        .isoformat()
        .replace("+00:00", "Z"),
        "bucket_width": "1d",
        "limit": 31,
    }
    headers = {"x-api-key": admin_key, "anthropic-version": "2023-06-01"}
    cents = 0.0
    while True:
        r = await client.get(COST_REPORT_URL, params=params, headers=headers)
        r.raise_for_status()
        body = r.json()
        for bucket in body.get("data", []):
            for item in bucket.get("results", []):
                cents += float(item["amount"])
        if not body.get("has_more"):
            return cents / 100
        params["page"] = body["next_page"]


async def anthropic(
    client: httpx.AsyncClient, s: Settings, today: date | None = None
) -> ProviderBalance:
    admin_key = (os.getenv("ANTHROPIC_ADMIN_KEY") or "").strip()
    if not admin_key:
        return _unconfigured("anthropic", "usd", "ANTHROPIC_ADMIN_KEY not set")
    today = today or datetime.now(UTC).date()
    try:
        start = _env_date("ANTHROPIC_CREDIT_START")
        expires = _env_date("ANTHROPIC_CREDIT_EXPIRES")
        budget = float(os.getenv("ANTHROPIC_CREDIT_USD") or 200)
        active = start is not None and expires is not None and start <= today < expires
        since = start if active else today.replace(day=1)
        spent = await anthropic_spent_usd(client, admin_key, since)
    except Exception as exc:  # noqa: BLE001 — best-effort by design
        return _error("anthropic", "usd", exc)
    if not active:
        return ProviderBalance(
            provider="anthropic",
            unit="usd",
            status="ok",
            detail=f"no active API credit; ${spent:.2f} spent this month "
            "(prepaid balance is not readable)",
        )
    remaining = budget - spent
    days_left = (expires - today).days
    status = classify(remaining, s.anthropic_low_usd, s.anthropic_critical_usd)
    if status == "ok" and days_left <= s.anthropic_expiry_warn_days:
        status = "low"
    return ProviderBalance(
        provider="anthropic",
        unit="usd",
        remaining=round(remaining, 2),
        limit=budget,
        resets_at=datetime(expires.year, expires.month, expires.day, tzinfo=UTC),
        status=status,
        detail=f"API credit expires in {days_left} d",
    )


async def openai(
    client: httpx.AsyncClient, s: Settings, today: date | None = None
) -> ProviderBalance:
    admin_key = (os.getenv("OPENAI_ADMIN_KEY") or "").strip()
    if not admin_key:
        return _unconfigured("openai", "usd", "OPENAI_ADMIN_KEY not set")
    today = today or datetime.now(UTC).date()
    month_start = datetime(today.year, today.month, 1, tzinfo=UTC)
    params: dict[str, object] = {
        "start_time": int(month_start.timestamp()),
        "bucket_width": "1d",
        "limit": 31,
    }
    spent = 0.0
    try:
        while True:
            r = await client.get(
                _OPENAI_COSTS,
                params=params,
                headers={"Authorization": f"Bearer {admin_key}"},
            )
            r.raise_for_status()
            body = r.json()
            for bucket in body.get("data", []):
                for item in bucket.get("results", []):
                    spent += float(item["amount"]["value"])
            if not body.get("has_more"):
                break
            params["page"] = body["next_page"]
    except Exception as exc:  # noqa: BLE001 — best-effort by design
        return _error("openai", "usd", exc)
    budget = s.openai_monthly_budget_usd
    remaining = budget - spent
    return ProviderBalance(
        provider="openai",
        unit="usd",
        remaining=round(remaining, 2),
        limit=budget,
        status=classify(remaining, budget * 0.25, budget * 0.10),
        detail=f"${spent:.2f} spent this month of a ${budget:.0f} budget",
    )


def _machine_usd(guest: dict) -> float:
    cpus = int(guest.get("cpus") or 1)
    mem = int(guest.get("memory_mb") or 256)
    if guest.get("cpu_kind") == "performance":
        return cpus * _FLY_PERF_CPU + max(0, mem - cpus * 2048) / 256 * _FLY_RAM_256MB
    return cpus * _FLY_SHARED_CPU + max(0, mem - cpus * 256) / 256 * _FLY_RAM_256MB


async def fly(client: httpx.AsyncClient, s: Settings) -> ProviderBalance:
    token = (os.getenv("FLY_METRICS_TOKEN") or "").strip()
    if not token:
        return _unconfigured("fly", "usd_month", "FLY_METRICS_TOKEN not set")
    headers = {"Authorization": token}
    try:
        r = await client.post(
            _FLY_GRAPHQL,
            headers=headers,
            json={
                "query": "query($s: String!) { organization(slug: $s) "
                "{ billingStatus } }",
                "variables": {"s": s.fly_org},
            },
        )
        r.raise_for_status()
        billing = r.json()["data"]["organization"]["billingStatus"]
        r = await client.get(
            f"{_FLY_MACHINES}/apps", params={"org_slug": s.fly_org}, headers=headers
        )
        r.raise_for_status()
        estimate = 0.0
        for app in r.json()["apps"]:
            name = app["name"]
            machines = await client.get(
                f"{_FLY_MACHINES}/apps/{name}/machines", headers=headers
            )
            machines.raise_for_status()
            estimate += sum(
                _machine_usd(m["config"].get("guest", {}))
                for m in machines.json()
                if m.get("state") == "started"
            )
            volumes = await client.get(
                f"{_FLY_MACHINES}/apps/{name}/volumes", headers=headers
            )
            volumes.raise_for_status()
            estimate += sum(v["size_gb"] * _FLY_VOLUME_GB for v in volumes.json())
    except Exception as exc:  # noqa: BLE001 — best-effort by design
        return _error("fly", "usd_month", exc)
    return ProviderBalance(
        provider="fly",
        unit="usd_month",
        monthly_usd=round(estimate, 2),
        status="ok" if billing == "CURRENT" else "critical",
        detail=f"billing {billing}; ~${estimate:.0f}/month if the machines running "
        "now kept running (list prices, volumes included)",
    )
