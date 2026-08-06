"""Per-order spend ceiling + attempt budget (#145 — pack order spend ceiling).

Why these matter: this module is the ONLY thing standing between a €4.99
purchase and an unbounded number of ~$4.23 frontier pipeline runs. Each test
pins a property the money guard would be useless without — that the default
ceiling is *derived from the measured COGS* rather than a number someone typed,
that an operator can move it per tier without a code deploy, and that both
guards (cents and attempts) actually refuse.
"""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from app import order_budget


def _order(product_id: str = "pack_30") -> SimpleNamespace:
    return SimpleNamespace(id="order-1", product_id=product_id)


def _job(*, spent: int = 0, attempts: int = 0) -> SimpleNamespace:
    return SimpleNamespace(cumulative_cost_cents=spent, retry_count=attempts)


def test_default_ceiling_is_a_multiple_of_the_measured_pack_cogs() -> None:
    """The default must trace to the measured pack_30 COGS (#139/#143), not a
    magic constant: if the measurement is updated the ceiling moves with it."""
    assert order_budget.MEASURED_COGS_CENTS["pack_30"] == 423  # $4.23, measured
    assert order_budget.spend_ceiling_cents("pack_30") == int(
        order_budget.DEFAULT_CEILING_MULTIPLIER * 423
    )


def test_unmeasured_tier_falls_back_to_the_measured_figure() -> None:
    """A tier nobody has measured yet must still get a ceiling — silently
    returning "no limit" for a new product id is how the hole reopens."""
    assert order_budget.spend_ceiling_cents("pack_50") == int(
        order_budget.DEFAULT_CEILING_MULTIPLIER * order_budget.FALLBACK_COGS_CENTS
    )


def test_ceiling_is_configurable_per_tier(monkeypatch: pytest.MonkeyPatch) -> None:
    """Per-tier env override — the lever for raising one expensive tier's
    ceiling in prod without redeploying code or touching the others."""
    monkeypatch.setenv("ORDER_SPEND_CEILING_CENTS_PACK_30", "900")
    assert order_budget.spend_ceiling_cents("pack_30") == 900
    assert order_budget.spend_ceiling_cents("pack_10") != 900


def test_multiplier_is_configurable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ORDER_SPEND_CEILING_MULTIPLIER", "1")
    assert order_budget.spend_ceiling_cents("pack_30") == 423


def test_junk_config_falls_back_to_the_default(monkeypatch: pytest.MonkeyPatch) -> None:
    """A typo'd secret must not disable the guard (fail loud in the log, safe
    in behaviour) — an unparsable ceiling that read as 0 would refuse every
    retry, and one that read as infinity would refuse none."""
    monkeypatch.setenv("ORDER_SPEND_CEILING_MULTIPLIER", "three")
    monkeypatch.setenv("ORDER_ATTEMPT_BUDGET", "lots")
    assert order_budget.spend_ceiling_cents("pack_30") == int(
        order_budget.DEFAULT_CEILING_MULTIPLIER * 423
    )
    assert order_budget.attempt_budget() == order_budget.DEFAULT_ATTEMPT_BUDGET


def test_spend_ceiling_refuses_when_cumulative_spend_reaches_it() -> None:
    ceiling = order_budget.spend_ceiling_cents("pack_30")
    verdict = order_budget.evaluate(_order(), _job(spent=ceiling, attempts=1))
    assert verdict.ok is False
    assert verdict.reason == "spend_ceiling"
    # The refusal must name the number — it is what the client sees in the 422
    # and what the Sentry event is triaged on.
    assert str(ceiling) in verdict.detail


def test_attempt_budget_refuses_cheap_attempts_that_never_hit_the_ceiling() -> None:
    """The second guard exists for exactly this case: attempts that fail early
    and cheap would otherwise loop forever under an unreached cents ceiling."""
    verdict = order_budget.evaluate(
        _order(), _job(spent=0, attempts=order_budget.attempt_budget())
    )
    assert verdict.ok is False
    assert verdict.reason == "attempt_budget"


def test_healthy_order_is_allowed() -> None:
    verdict = order_budget.evaluate(_order(), _job(spent=10, attempts=1))
    assert verdict.ok is True
    assert verdict.reason is None


def test_mark_exhausted_leaves_the_refundable_terminal_state() -> None:
    """`refund_eligible` is the only machine-readable "this purchase owes a
    refund" signal — a cut-off order that skipped it is money kept for nothing."""
    order = SimpleNamespace(id="o", product_id="pack_30", status="in_progress",
                            refund_eligible=False)
    job = SimpleNamespace(status="generating", error=None,
                          cumulative_cost_cents=99999, retry_count=9)
    verdict = order_budget.evaluate(order, job)
    order_budget.mark_exhausted(order, job, verdict)

    assert order.status == "failed"
    assert order.refund_eligible is True
    assert job.status == "failed"
    assert verdict.detail in job.error
