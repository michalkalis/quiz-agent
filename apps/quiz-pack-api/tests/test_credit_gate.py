"""API credit first, subscription after (#196 track 196.7).

Why these matter:
- The monthly Max API credit is free money that expires; corpus batches should
  use it while there is room, and only then fall back to the subscription.
- The reserve protects prod custom packs (always API) from corpus eating the
  whole credit, and covers the ~5 min cost-report lag.
- Anything we cannot see (no admin key, expired credit, API error) must pick
  the subscription: a gate that fails open would silently spend real money.
"""

from __future__ import annotations

from datetime import date

import httpx
import pytest
from quiz_shared.llm import credit_gate

TODAY = date(2026, 10, 15)


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")
    monkeypatch.setenv("ANTHROPIC_ADMIN_KEY", "sk-ant-admin-test")
    monkeypatch.setenv("ANTHROPIC_CREDIT_START", "2026-10-09")
    monkeypatch.setenv("ANTHROPIC_CREDIT_EXPIRES", "2026-11-06")
    monkeypatch.delenv("ANTHROPIC_CREDIT_USD", raising=False)
    monkeypatch.delenv("ANTHROPIC_CREDIT_RESERVE_USD", raising=False)


def _client(
    pages: list[list[str]], seen: list[httpx.Request] | None = None
) -> httpx.Client:
    """Fake cost report: each page is a list of cent amounts in one bucket."""

    def handler(request: httpx.Request) -> httpx.Response:
        if seen is not None:
            seen.append(request)
        idx = int(request.url.params.get("page", "0"))
        last = idx == len(pages) - 1
        return httpx.Response(
            200,
            json={
                "data": [
                    {"results": [{"amount": a, "currency": "USD"} for a in pages[idx]]}
                ],
                "has_more": not last,
                "next_page": None if last else str(idx + 1),
            },
        )

    return httpx.Client(transport=httpx.MockTransport(handler))


def test_credit_left_uses_api_and_sums_every_page():
    seen: list[httpx.Request] = []
    # $40 + $35.50 over two pages -> $124.50 left, well above the $25 reserve.
    decision = credit_gate.decide(
        TODAY, client=_client([["4000"], ["3000", "550"]], seen)
    )
    assert decision.route == credit_gate.API
    assert "$124.50" in decision.reason
    assert len(seen) == 2
    assert seen[0].headers["x-api-key"] == "sk-ant-admin-test"
    assert seen[0].url.params["starting_at"].startswith("2026-10-09")


def test_reserve_reached_switches_to_session():
    # $176 spent -> $24 left <= $25 reserve: the rest stays for prod packs.
    decision = credit_gate.decide(TODAY, client=_client([["17600"]]))
    assert decision.route == credit_gate.SESSION


def test_custom_budget_and_reserve(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_CREDIT_USD", "100")
    monkeypatch.setenv("ANTHROPIC_CREDIT_RESERVE_USD", "10")
    assert (
        credit_gate.decide(TODAY, client=_client([["8900"]])).route == credit_gate.API
    )
    assert (
        credit_gate.decide(TODAY, client=_client([["9000"]])).route
        == credit_gate.SESSION
    )


@pytest.mark.parametrize(
    ("unset", "today"),
    [
        ("ANTHROPIC_ADMIN_KEY", TODAY),
        ("ANTHROPIC_API_KEY", TODAY),
        ("ANTHROPIC_CREDIT_START", TODAY),
        (None, date(2026, 11, 6)),  # expiry day: the credit is gone
        (None, date(2026, 10, 8)),  # before the credit was granted
    ],
)
def test_unknown_state_fails_safe_to_session(monkeypatch, unset, today):
    if unset:
        monkeypatch.delenv(unset)
    decision = credit_gate.decide(today, client=_client([["0"]]))
    assert decision.route == credit_gate.SESSION


def test_cost_report_error_fails_safe_to_session():
    client = httpx.Client(
        transport=httpx.MockTransport(lambda r: httpx.Response(401, json={}))
    )
    decision = credit_gate.decide(TODAY, client=client)
    assert decision.route == credit_gate.SESSION
    assert "cost report failed" in decision.reason
