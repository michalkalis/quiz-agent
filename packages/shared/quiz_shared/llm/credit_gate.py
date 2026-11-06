"""API credit first, Claude subscription after (#196 track 196.7).

Founder 2026-10-10: offline corpus generation should draw on the monthly
Anthropic API credit from the Max plan while it lasts, then fall back to the
Claude subscription (``LLM_GATEWAY=session``). Customer packs on prod are NOT
gated here — they always use the API (the subscription is not a backend for
paying customers).

The decision is taken once per batch, before it starts, so a batch never
changes route halfway through. It reads the organisation's real spend from the
Anthropic Cost API (Admin key; data lags ~5 min), so prod pack generation and
every other consumer of the same credit are counted too. A reserve stays
untouched for prod packs and for the reporting lag.

Fail-safe: anything unknown (no admin key, credit expired, API error) picks
the subscription — never spend money we cannot see.

CLI: ``python -m quiz_shared.llm.credit_gate`` prints ``api`` or ``session``
on stdout and the reason on stderr.
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from datetime import UTC, date, datetime

import httpx

COST_REPORT_URL = "https://api.anthropic.com/v1/organizations/cost_report"
API = "api"
SESSION = "session"

DEFAULT_RESERVE_USD = 25.0

# The Max plan's monthly API credit, as Claude Console → Billing →
# Promotional credits shows it. Not a secret, so it lives here (one place for
# this gate and the prod cost monitor) and is updated by PR when a new grant
# appears. Start is the first day this grant is drawn: the 2026-11-03 grant
# only took over once the previous one expired on 2026-11-06; 11-05 is used
# because the cost report refuses a window starting today (counts ~$6 extra,
# the safe direction).
CREDIT_START = date(2026, 11, 5)
CREDIT_EXPIRES = date(2026, 12, 6)  # first day the credit is gone
CREDIT_USD = 200.0


@dataclass(frozen=True)
class Decision:
    route: str  # API or SESSION
    reason: str


def _env_float(name: str, default: float) -> float:
    raw = (os.getenv(name) or "").strip()
    return float(raw) if raw else default


def spent_usd(
    admin_key: str, since: date, *, client: httpx.Client | None = None
) -> float:
    """Organisation spend (USD) from ``since`` 00:00 UTC until now."""
    params: dict[str, object] = {
        "starting_at": datetime(
            since.year, since.month, since.day, tzinfo=UTC
        ).isoformat(),
        "bucket_width": "1d",
        "limit": 31,
    }
    headers = {"x-api-key": admin_key, "anthropic-version": "2023-06-01"}
    cents = 0.0
    with client or httpx.Client(timeout=20.0) as http:
        while True:
            resp = http.get(COST_REPORT_URL, params=params, headers=headers)
            resp.raise_for_status()
            body = resp.json()
            for bucket in body.get("data", []):
                for item in bucket.get("results", []):
                    cents += float(item["amount"])
            if not body.get("has_more"):
                return cents / 100
            params["page"] = body["next_page"]


def decide(
    today: date | None = None, *, client: httpx.Client | None = None
) -> Decision:
    today = today or datetime.now(UTC).date()
    if not (os.getenv("ANTHROPIC_API_KEY") or "").strip():
        return Decision(SESSION, "ANTHROPIC_API_KEY not set")
    admin_key = (os.getenv("ANTHROPIC_ADMIN_KEY") or "").strip()
    if not admin_key:
        return Decision(SESSION, "ANTHROPIC_ADMIN_KEY not set, spend unknown")
    try:
        reserve = _env_float("ANTHROPIC_CREDIT_RESERVE_USD", DEFAULT_RESERVE_USD)
    except ValueError as exc:
        return Decision(SESSION, f"bad credit config: {exc}")
    start, expires, budget = CREDIT_START, CREDIT_EXPIRES, CREDIT_USD
    if not start <= today < expires:
        return Decision(SESSION, f"no active credit (period {start}..{expires})")
    try:
        spent = spent_usd(admin_key, start, client=client)
    except (httpx.HTTPError, KeyError, ValueError) as exc:
        return Decision(SESSION, f"cost report failed: {exc}")
    left = budget - spent
    if left <= reserve:
        return Decision(
            SESSION,
            f"credit nearly used: ${spent:.2f} of ${budget:.0f} spent, reserve ${reserve:.0f}",
        )
    return Decision(
        API, f"${left:.2f} of ${budget:.0f} credit left (reserve ${reserve:.0f})"
    )


def main() -> int:
    decision = decide()
    print(decision.route)
    print(f"credit_gate: {decision.route} — {decision.reason}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
