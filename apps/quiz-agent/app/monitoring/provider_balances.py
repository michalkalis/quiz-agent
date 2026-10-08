"""Provider credit balances (#193 — beta hardening).

During the beta a provider ran out of credit and testers could not play, and
nobody knew until they said so. This module reads the account-level balance of
every prepaid provider the live quiz depends on, so the founder sees it coming:
an admin endpoint shows the numbers on demand, and a daily background check
raises a Sentry issue (which emails the founder) when one runs low.

Only providers with a balance API are covered: OpenRouter (account credits and
the key's own spend limit) and ElevenLabs (character quota). OpenAI and
Anthropic expose no balance to a normal API key. Tavily is used only by pack
generation in quiz-pack-api, so it is not checked here.

Every fetch is best-effort: short timeout, never raises, never logs a key.
A failed fetch becomes ``status="error"`` so one dead provider API can't hide
the others.
"""

from __future__ import annotations

import asyncio
import logging
import os
import random
from contextlib import nullcontext
from datetime import UTC, datetime
from typing import Literal

import httpx
import sentry_sdk
from pydantic import BaseModel

from ..config import Settings

logger = logging.getLogger(__name__)

Status = Literal["ok", "low", "critical", "error"]

_TIMEOUT = httpx.Timeout(5.0)
_OPENROUTER = "https://openrouter.ai/api/v1"
_ELEVENLABS_SUBSCRIPTION = "https://api.elevenlabs.io/v1/user/subscription"


class ProviderBalance(BaseModel):
    provider: str
    unit: str
    remaining: float | None = None
    limit: float | None = None
    resets_at: datetime | None = None
    status: Status
    detail: str | None = None


def classify(remaining: float, low: float, critical: float) -> Status:
    """Below `critical` → critical, below `low` → low, else ok (same unit)."""
    if remaining < critical:
        return "critical"
    if remaining < low:
        return "low"
    return "ok"


def _error(provider: str, unit: str, detail: str) -> ProviderBalance:
    return ProviderBalance(provider=provider, unit=unit, status="error", detail=detail)


def _describe(exc: Exception) -> str:
    # Status code or exception type only: exception text can echo request data.
    if isinstance(exc, httpx.HTTPStatusError):
        return f"HTTP {exc.response.status_code}"
    return type(exc).__name__


async def _openrouter(client: httpx.AsyncClient, s: Settings) -> list[ProviderBalance]:
    key = os.getenv("OPENROUTER_API_KEY")
    if not key:
        return [_error("openrouter", "usd", "OPENROUTER_API_KEY not set")]
    headers = {"Authorization": f"Bearer {key}"}
    out: list[ProviderBalance] = []
    try:
        r = await client.get(f"{_OPENROUTER}/credits", headers=headers)
        r.raise_for_status()
        data = r.json()["data"]
        total = float(data["total_credits"])
        remaining = total - float(data["total_usage"])
        out.append(
            ProviderBalance(
                provider="openrouter",
                unit="usd",
                remaining=round(remaining, 2),
                limit=total,
                status=classify(
                    remaining, s.openrouter_low_usd, s.openrouter_critical_usd
                ),
            )
        )
    except Exception as exc:  # noqa: BLE001 — best-effort by design
        out.append(_error("openrouter", "usd", _describe(exc)))
    # The key can carry its own spend cap (e.g. $50/month) that cuts calls off
    # even while the account still has credit. No cap set → nothing to report.
    try:
        r = await client.get(f"{_OPENROUTER}/key", headers=headers)
        r.raise_for_status()
        data = r.json()["data"]
        if data.get("limit") is not None and data.get("limit_remaining") is not None:
            left = float(data["limit_remaining"])
            out.append(
                ProviderBalance(
                    provider="openrouter_key",
                    unit="usd",
                    remaining=round(left, 2),
                    limit=float(data["limit"]),
                    status=classify(
                        left, s.openrouter_low_usd, s.openrouter_critical_usd
                    ),
                    detail=f"key limit resets {data.get('limit_reset') or 'never'}",
                )
            )
    except Exception as exc:  # noqa: BLE001 — best-effort by design
        out.append(_error("openrouter_key", "usd", _describe(exc)))
    return out


async def _elevenlabs(client: httpx.AsyncClient, s: Settings) -> list[ProviderBalance]:
    key = os.getenv("ELEVENLABS_API_KEY")
    if not key:
        return [_error("elevenlabs", "characters", "ELEVENLABS_API_KEY not set")]
    try:
        r = await client.get(_ELEVENLABS_SUBSCRIPTION, headers={"xi-api-key": key})
        r.raise_for_status()
        data = r.json()
        limit = float(data["character_limit"])
        remaining = limit - float(data["character_count"])
        reset = data.get("next_character_count_reset_unix")
        return [
            ProviderBalance(
                provider="elevenlabs",
                unit="characters",
                remaining=remaining,
                limit=limit,
                resets_at=datetime.fromtimestamp(reset, UTC) if reset else None,
                status=classify(
                    remaining,
                    limit * s.elevenlabs_low_pct / 100,
                    limit * s.elevenlabs_critical_pct / 100,
                ),
                detail=data.get("tier"),
            )
        ]
    except Exception as exc:  # noqa: BLE001 — best-effort by design
        return [_error("elevenlabs", "characters", _describe(exc))]


async def fetch_provider_balances(
    settings: Settings, client: httpx.AsyncClient | None = None
) -> list[ProviderBalance]:
    """All provider balances; never raises."""
    # A caller-supplied client (tests) is borrowed, not closed.
    owned = (
        httpx.AsyncClient(timeout=_TIMEOUT) if client is None else nullcontext(client)
    )
    async with owned as c:
        groups = await asyncio.gather(
            _openrouter(c, settings), _elevenlabs(c, settings)
        )
    return [b for group in groups for b in group]


def report_to_sentry(balances: list[ProviderBalance]) -> None:
    """One Sentry issue per provider+status (stable fingerprint), so a balance
    that stays low for days adds events to one issue instead of new emails."""
    for b in balances:
        if b.status == "error":
            logger.warning(
                "Provider balance check failed: %s (%s)", b.provider, b.detail
            )
            continue
        if b.status == "ok":
            continue
        sentry_sdk.capture_message(
            f"{b.provider} balance {b.status}: {b.remaining:g} {b.unit} left",
            level="error" if b.status == "critical" else "warning",
            fingerprint=["provider-balance", b.provider, b.status],
            tags={"provider": b.provider},
            contexts={"balance": b.model_dump(mode="json")},
        )
        logger.warning(
            "Provider balance %s: %s %s %s left",
            b.status,
            b.provider,
            b.remaining,
            b.unit,
        )


async def run_daily_balance_check(settings: Settings) -> None:
    """Background loop: shortly after startup, then every ~24 h. Runs off the
    request path; the first check waits so it never delays boot."""
    await asyncio.sleep(settings.provider_balance_initial_delay_s)
    while True:
        try:
            report_to_sentry(await fetch_provider_balances(settings))
        except Exception:
            logger.exception("Provider balance check crashed")
        await asyncio.sleep(24 * 3600 + random.uniform(0, 600))
