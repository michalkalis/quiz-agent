"""Spend-based provider checks (#207 — production readiness, 207.12).

Why these matter: Anthropic, OpenAI and Fly show no balance to a normal key,
so these checks are the only early warning before a credit or a card runs
out. They are trustworthy only if
- Anthropic remaining = the period's credit minus REAL org spend since the
  period start (not since month start), and an expiring credit warns even
  when plenty is left — after expiry calls bill the prepaid balance;
- OpenAI spend is summed across pages (a missed page under-reports spend);
- a failed Fly card (billing not CURRENT) is critical: Fly suspends apps;
- a missing admin credential is shown, never alerted (optional keys).
"""

from __future__ import annotations

from datetime import date

import httpx
import pytest
from app.config import Settings
from app.monitoring import provider_costs as pc
from httpx import MockTransport, Response

pytestmark = pytest.mark.asyncio

_S = Settings()  # Anthropic low <$40 / critical <$15, warn 3 d; OpenAI $50
TODAY = date(2026, 10, 20)


def _client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=MockTransport(handler))


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_ADMIN_KEY", "sk-ant-admin-secret")
    monkeypatch.setenv("ANTHROPIC_CREDIT_START", "2026-10-09")
    monkeypatch.setenv("ANTHROPIC_CREDIT_EXPIRES", "2026-11-06")
    monkeypatch.setenv("ANTHROPIC_CREDIT_USD", "200")
    monkeypatch.setenv("OPENAI_ADMIN_KEY", "sk-admin-secret")
    monkeypatch.setenv("FLY_METRICS_TOKEN", "FlyV1 fm2_secret")


def _anthropic_handler(cents: list[str], seen: list[httpx.Request]):
    def handler(request: httpx.Request) -> Response:
        seen.append(request)
        return Response(
            200,
            json={
                "data": [{"results": [{"amount": c}]} for c in cents],
                "has_more": False,
            },
        )

    return handler


@pytest.mark.parametrize(
    "spent_cents, expected", [("15000", "ok"), ("17000", "low"), ("19000", "critical")]
)
async def test_anthropic_remaining_is_credit_minus_spend_since_period_start(
    spent_cents, expected
):
    seen: list[httpx.Request] = []
    async with _client(_anthropic_handler([spent_cents], seen)) as c:
        b = await pc.anthropic(c, _S, TODAY)
    assert b.status == expected
    assert b.remaining == pytest.approx(200 - int(spent_cents) / 100)
    # Spend counted from the credit start, not the calendar month.
    assert seen[0].url.params["starting_at"].startswith("2026-10-09")


async def test_anthropic_credit_about_to_expire_warns_even_with_money_left():
    """After expiry, calls silently bill the prepaid balance instead."""
    async with _client(_anthropic_handler(["1000"], [])) as c:
        b = await pc.anthropic(c, _S, date(2026, 11, 4))
    assert b.status == "low"
    assert "expires in 2 d" in (b.detail or "")


async def test_anthropic_outside_credit_period_reports_month_spend_only():
    seen: list[httpx.Request] = []
    async with _client(_anthropic_handler(["2500"], seen)) as c:
        b = await pc.anthropic(c, _S, date(2026, 11, 10))
    assert b.status == "ok" and b.remaining is None
    assert "$25.00" in (b.detail or "")
    assert seen[0].url.params["starting_at"].startswith("2026-11-01")


async def test_openai_spend_sums_all_pages_against_budget():
    def handler(request: httpx.Request) -> Response:
        if request.url.params.get("page") == "p2":
            return Response(
                200,
                json={
                    "data": [{"results": [{"amount": {"value": 20.0}}]}],
                    "has_more": False,
                },
            )
        return Response(
            200,
            json={
                "data": [{"results": [{"amount": {"value": 21.0}}]}],
                "has_more": True,
                "next_page": "p2",
            },
        )

    async with _client(handler) as c:
        b = await pc.openai(c, _S, TODAY)
    assert b.remaining == pytest.approx(9.0)  # $50 budget − $41 spent
    assert b.status == "low"  # under 25 % of the budget left


def _fly_handler(billing: str):
    def handler(request: httpx.Request) -> Response:
        path = request.url.path
        if path == "/graphql":
            return Response(
                200, json={"data": {"organization": {"billingStatus": billing}}}
            )
        if path == "/v1/apps":
            return Response(200, json={"apps": [{"name": "quiz-agent-api"}]})
        if path.endswith("/machines"):
            return Response(
                200,
                json=[
                    {
                        "state": "started",
                        "config": {
                            "guest": {"cpu_kind": "shared", "cpus": 1, "memory_mb": 512}
                        },
                    },
                    {"state": "stopped", "config": {"guest": {"memory_mb": 8192}}},
                ],
            )
        if path.endswith("/volumes"):
            return Response(200, json=[{"size_gb": 10}])
        return Response(404)

    return handler


async def test_fly_estimate_counts_running_machines_and_all_volumes():
    async with _client(_fly_handler("CURRENT")) as c:
        b = await pc.fly(c, _S)
    assert b.status == "ok"
    # shared-cpu-1x 512 MB ($1.94 + $1.25) + 10 GB volume ($1.50); stopped = 0.
    assert b.monthly_usd == pytest.approx(4.69)


@pytest.mark.parametrize(
    "billing, expected",
    [("PAST_DUE", "critical"), ("DELINQUENT", "critical"), ("TRIAL_ACTIVE", "ok")],
)
async def test_fly_failed_card_is_critical(billing, expected):
    """Only states in which Fly suspends apps page; others must not alert daily."""
    async with _client(_fly_handler(billing)) as c:
        b = await pc.fly(c, _S)
    assert b.status == expected


@pytest.mark.parametrize(
    "var, fn",
    [
        ("ANTHROPIC_ADMIN_KEY", pc.anthropic),
        ("OPENAI_ADMIN_KEY", pc.openai),
        ("FLY_METRICS_TOKEN", pc.fly),
    ],
)
async def test_missing_admin_credential_is_unconfigured(monkeypatch, var, fn):
    monkeypatch.delenv(var)
    async with _client(lambda r: Response(500)) as c:
        b = await fn(c, _S)
    assert b.status == "unconfigured"


async def test_api_failure_is_error_and_never_leaks_key():
    async with _client(lambda r: Response(401)) as c:
        got = [await pc.anthropic(c, _S, TODAY), await pc.openai(c, _S, TODAY)]
        got.append(await pc.fly(c, _S))
    assert {b.status for b in got} == {"error"}
    assert "secret" not in str([b.model_dump() for b in got])
