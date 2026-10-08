"""Provider credit balances (#193 — beta hardening).

In the beta a provider ran out of credit and testers could not play; the
founder learned it from them. These tests pin what makes the early warning
trustworthy:
- the thresholds fire on the right side of the line (a missed "critical" is
  the outage we are preventing; a false one trains the founder to ignore it);
- a broken provider API is reported as `error`, never an exception — the check
  runs in a background loop and an admin endpoint, and must not take either
  down or hide the other providers;
- alerts carry a fingerprint per provider+status, so a balance that stays low
  for a week is one Sentry email, not seven;
- the endpoint is admin-only (it reveals spend).
"""

from __future__ import annotations

import httpx
import pytest
from app.api.routes import provider_balances as route
from app.config import Settings
from app.monitoring import provider_balances as pb
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient, MockTransport, Response

pytestmark = pytest.mark.asyncio

_SETTINGS = Settings()  # defaults: OpenRouter low <$10 / critical <$3; EL 25 % / 10 %


def _client(
    *, credits=(100.0, 0.0), key=None, el=(0, 10000), fail: set[str] = frozenset()
) -> httpx.AsyncClient:
    """Fake OpenRouter + ElevenLabs. `fail` names paths that return 500."""

    def handler(request: httpx.Request) -> Response:
        path = request.url.path
        if path in fail:
            return Response(500, json={"error": "boom"})
        if path == "/api/v1/credits":
            total, usage = credits
            return Response(
                200, json={"data": {"total_credits": total, "total_usage": usage}}
            )
        if path == "/api/v1/key":
            limit, left = key if key else (None, None)
            return Response(
                200,
                json={
                    "data": {
                        "limit": limit,
                        "limit_remaining": left,
                        "limit_reset": "monthly",
                    }
                },
            )
        if path == "/v1/user/subscription":
            used, limit = el
            return Response(
                200,
                json={
                    "tier": "starter",
                    "character_count": used,
                    "character_limit": limit,
                    "next_character_count_reset_unix": 1792508544,
                },
            )
        return Response(404)

    return httpx.AsyncClient(transport=MockTransport(handler))


@pytest.fixture(autouse=True)
def _keys(monkeypatch):
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-secret-test-key")
    monkeypatch.setenv("ELEVENLABS_API_KEY", "xi-secret-test-key")


async def _fetch(**kw) -> dict[str, pb.ProviderBalance]:
    async with _client(**kw) as c:
        return {b.provider: b for b in await pb.fetch_provider_balances(_SETTINGS, c)}


@pytest.mark.parametrize(
    "usage, expected",
    [(80.0, "ok"), (90.01, "low"), (97.01, "critical")],  # $20, $9.99, $2.99 left
)
async def test_openrouter_remaining_is_credits_minus_usage(usage, expected):
    """Remaining = total_credits − total_usage; thresholds apply to that, so a
    $95 account that has spent $86 alerts even though "credits" looks healthy."""
    b = (await _fetch(credits=(100.0, usage)))["openrouter"]
    assert b.status == expected
    assert b.remaining == pytest.approx(100.0 - usage)


@pytest.mark.parametrize(
    "used, expected", [(7000, "ok"), (8000, "low"), (9500, "critical")]
)
async def test_elevenlabs_thresholds_are_percent_of_quota(used, expected):
    """30 % / 20 % / 5 % of a 10 000-character quota left. Percent, not a fixed
    count, so the alert still means the same thing after a plan change."""
    b = (await _fetch(el=(used, 10000)))["elevenlabs"]
    assert b.status == expected
    assert b.remaining == 10000 - used
    assert b.resets_at is not None and b.resets_at.tzinfo is not None


async def test_openrouter_key_cap_reported_only_when_set():
    """A key's own monthly cap cuts calls off while the account still has
    credit — the founder must see it; with no cap there is nothing to watch."""
    assert "openrouter_key" not in await _fetch()
    b = (await _fetch(key=(50.0, 2.0)))["openrouter_key"]
    assert b.status == "critical"


async def test_provider_api_failure_is_error_status_not_exception():
    """One provider's API down must not raise or hide the others."""
    got = await _fetch(fail={"/api/v1/credits"})
    assert got["openrouter"].status == "error"
    assert got["openrouter"].detail == "HTTP 500"
    assert got["elevenlabs"].status == "ok"


async def test_unreachable_provider_is_error_and_never_leaks_key():
    def boom(request):
        raise httpx.ConnectTimeout("timed out", request=request)

    async with httpx.AsyncClient(transport=MockTransport(boom)) as c:
        got = await pb.fetch_provider_balances(_SETTINGS, c)
    assert {b.status for b in got} == {"error"}
    dumped = str([b.model_dump() for b in got])
    assert "secret-test-key" not in dumped


async def test_missing_key_is_error_not_silently_skipped(monkeypatch):
    """An unset key in prod is a misconfig the endpoint should show."""
    monkeypatch.delenv("ELEVENLABS_API_KEY")
    assert (await _fetch())["elevenlabs"].status == "error"


async def test_sentry_alert_fingerprint_is_stable_per_provider_and_status(monkeypatch):
    """Same provider+status → same fingerprint regardless of the amount, so
    daily repeats group into one issue (one email); ok and error never alert."""
    captured: list[tuple[list[str], str]] = []

    def fake_capture(message, level=None, **scope_kwargs):
        captured.append((scope_kwargs["fingerprint"], level))

    monkeypatch.setattr(pb.sentry_sdk, "capture_message", fake_capture)
    day1 = [
        pb.ProviderBalance(
            provider="openrouter", unit="usd", remaining=8.0, status="low"
        ),
        pb.ProviderBalance(
            provider="elevenlabs", unit="characters", remaining=900, status="critical"
        ),
        pb.ProviderBalance(provider="x", unit="usd", remaining=50.0, status="ok"),
        pb.ProviderBalance(provider="y", unit="usd", status="error", detail="HTTP 500"),
    ]
    day2 = [
        pb.ProviderBalance(
            provider="openrouter", unit="usd", remaining=6.5, status="low"
        )
    ]
    pb.report_to_sentry(day1)
    pb.report_to_sentry(day2)
    assert captured == [
        (["provider-balance", "openrouter", "low"], "warning"),
        (["provider-balance", "elevenlabs", "critical"], "error"),
        (["provider-balance", "openrouter", "low"], "warning"),
    ]


async def test_background_check_is_opt_in():
    """Tests and local dev must make no outbound provider calls by default."""
    assert Settings().provider_balance_check_enabled is False


@pytest.fixture
def api(monkeypatch):
    monkeypatch.setenv("ADMIN_API_KEY", "admin-secret")

    async def fake_fetch(settings):
        return [
            pb.ProviderBalance(
                provider="openrouter", unit="usd", remaining=42.0, status="ok"
            )
        ]

    monkeypatch.setattr(route, "fetch_provider_balances", fake_fetch)
    app = FastAPI()
    app.include_router(route.router, prefix="/api/v1")
    return AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


@pytest.mark.parametrize("headers", [{}, {"X-Admin-Key": "wrong"}])
async def test_endpoint_rejects_without_valid_admin_key(api, headers):
    """Balances reveal spend; never public."""
    async with api as c:
        r = await c.get("/api/v1/admin/provider-balances", headers=headers)
    assert r.status_code in (401, 422)
    assert "remaining" not in r.text


async def test_endpoint_returns_balances_with_admin_key(api):
    async with api as c:
        r = await c.get(
            "/api/v1/admin/provider-balances", headers={"X-Admin-Key": "admin-secret"}
        )
    assert r.status_code == 200
    assert r.json()[0]["provider"] == "openrouter"
    assert r.json()[0]["status"] == "ok"
