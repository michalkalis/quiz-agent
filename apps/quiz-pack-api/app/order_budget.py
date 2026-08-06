"""Per-order spend ceiling + lifetime attempt budget (#145 — pack order spend ceiling).

WHY: every attempt at a pack order runs the FULL frontier pipeline (sourcing →
generation → critique → judge panel), measured at ~$4.23 for a ``pack_30`` run
(#139 cost datapoint, #143 pack COGS). Nothing in the order/job layer used to
know how much money one purchase had already burned: ``POST /retry`` zeroed the
auto-attempt counter, so a single ~€4.99 purchase could walk through four
independent 3-attempt budgets (~12 paid runs), and cost was only ever recorded
on delivery — so the spend left no trace at all.

This module is the ONE place that answers "may this order spend another
attempt?". Three call sites consult it and none of them re-implements it:

- ``app.api.v1.orders.retry_order`` — refuses the manual retry with a 4xx,
- ``app.worker.sweep._recover_stuck_order`` — force-fails instead of re-enqueuing,
- ``app.worker.tasks.process_order`` — refuses to start a paid attempt (this is
  the one that also stops ARQ's own in-sequence retries, which reach no other
  gate).

Two independent guards, deliberately: the **spend ceiling** binds first on
expensive tiers, the **lifetime attempt budget** on cheap ones (a tier whose
attempts are nearly free would otherwise never hit a cents ceiling).

Env-driven like the other generation/order knobs (see ``app.feature_flags``
docstring) so a tier's ceiling moves with a Fly secret, not a code deploy.
"""

from __future__ import annotations

import logging
import os
import uuid
from dataclasses import dataclass
from typing import Any, Optional, Sequence

import sentry_sdk

logger = logging.getLogger(__name__)

# Measured all-in cost of ONE full pipeline run, per product tier, in cents.
# pack_30 = $4.23, measured on the 2026-08-04 prod run (#139 observability
# work, carried into #143 pack COGS). Tiers without their own measurement fall
# back to this figure rather than a guess: the ceiling is a safety cap, and
# over-estimating a cheap tier's COGS only means the *attempt* budget binds
# first, which is the intended division of labour between the two guards.
MEASURED_COGS_CENTS: dict[str, int] = {"pack_30": 423}
FALLBACK_COGS_CENTS = 423

# How many full-COGS runs one purchase may burn before the order is cut off.
# 3 keeps the worst case at ~$12.69 against a ~€4.99 purchase — already a loss,
# but a bounded and observable one, and generous enough that the common case
# (attempts that die early and cheap) still leaves room for a genuine manual
# retry. Override with ORDER_SPEND_CEILING_MULTIPLIER.
DEFAULT_CEILING_MULTIPLIER = 3.0

# Lifetime attempts for one order, across the initial ARQ sequence, sweep
# recoveries and manual retries. 6 = the initial 3-attempt ARQ sequence
# (WorkerSettings.max_tries) plus one more sequence's worth of recovery/manual
# attempts — vs the ~12 the pre-#145 code allowed. Override with
# ORDER_ATTEMPT_BUDGET.
DEFAULT_ATTEMPT_BUDGET = 6


def _env_int(name: str, default: int, minimum: int = 1) -> int:
    raw = (os.getenv(name) or "").strip()
    if not raw:
        return default
    try:
        return max(minimum, int(raw))
    except ValueError:
        logger.warning("ignoring non-integer %s=%r; using %s", name, raw, default)
        return default


def _env_float(name: str, default: float, minimum: float = 0.0) -> float:
    raw = (os.getenv(name) or "").strip()
    if not raw:
        return default
    try:
        return max(minimum, float(raw))
    except ValueError:
        logger.warning("ignoring non-numeric %s=%r; using %s", name, raw, default)
        return default


def tier_cogs_cents(product_id: str) -> int:
    """Measured cost of one full pipeline run for this product tier."""
    return MEASURED_COGS_CENTS.get(product_id, FALLBACK_COGS_CENTS)


def ceiling_multiplier() -> float:
    return _env_float("ORDER_SPEND_CEILING_MULTIPLIER", DEFAULT_CEILING_MULTIPLIER)


def spend_ceiling_cents(product_id: str) -> int:
    """Cumulative cents one order of this tier may spend across ALL attempts.

    Per-tier absolute override: ``ORDER_SPEND_CEILING_CENTS_PACK_30`` (product
    id upper-cased). Otherwise ``multiplier × measured tier COGS``.
    """
    override = _env_int(
        f"ORDER_SPEND_CEILING_CENTS_{(product_id or '').upper()}", default=0, minimum=0
    )
    if override:
        return override
    return int(round(ceiling_multiplier() * tier_cogs_cents(product_id)))


def attempt_budget() -> int:
    return _env_int("ORDER_ATTEMPT_BUDGET", DEFAULT_ATTEMPT_BUDGET)


@dataclass(frozen=True)
class BudgetVerdict:
    """May this order start another paid attempt, and if not, why."""

    ok: bool
    reason: Optional[str]  # 'spend_ceiling' | 'attempt_budget' | None
    detail: str
    spent_cents: int
    ceiling_cents: int
    attempts: int
    attempt_budget: int


def evaluate(order: Any, job: Any) -> BudgetVerdict:
    """Decide whether ``order`` may spend one more attempt.

    Reads only ``order.product_id`` / ``job.cumulative_cost_cents`` /
    ``job.retry_count`` so every caller (endpoint, sweep, worker) asks the same
    question of the same two persisted numbers.
    """
    spent = int(job.cumulative_cost_cents or 0)
    attempts = int(job.retry_count or 0)
    ceiling = spend_ceiling_cents(order.product_id)
    budget = attempt_budget()

    if spent >= ceiling:
        return BudgetVerdict(
            ok=False,
            reason="spend_ceiling",
            detail=(
                f"order spend ceiling reached: {spent} cents already spent across "
                f"{attempts} attempt(s), ceiling {ceiling} cents for product "
                f"{order.product_id!r}"
            ),
            spent_cents=spent,
            ceiling_cents=ceiling,
            attempts=attempts,
            attempt_budget=budget,
        )

    if attempts >= budget:
        return BudgetVerdict(
            ok=False,
            reason="attempt_budget",
            detail=(
                f"order attempt budget reached: {attempts} attempt(s) used of "
                f"{budget}, {spent} cents spent (ceiling {ceiling} cents)"
            ),
            spent_cents=spent,
            ceiling_cents=ceiling,
            attempts=attempts,
            attempt_budget=budget,
        )

    return BudgetVerdict(
        ok=True,
        reason=None,
        detail="",
        spent_cents=spent,
        ceiling_cents=ceiling,
        attempts=attempts,
        attempt_budget=budget,
    )


def mark_exhausted(order: Any, job: Any, verdict: BudgetVerdict) -> None:
    """Put the order in its terminal, refund-eligible state. Caller commits.

    Same terminal shape a naturally-exhausted ARQ job reaches, so the client
    and the refund pipeline need no new state: 'failed' + ``refund_eligible``,
    with the ceiling named in ``job.error``.
    """
    job.status = "failed"
    job.error = verdict.detail
    order.status = "failed"
    order.refund_eligible = True


def report_breach(
    order_id: uuid.UUID | str,
    verdict: BudgetVerdict,
    step_log_tail: Optional[Sequence[dict]] = None,
) -> None:
    """Error-level Sentry event for an order cut off by a budget guard.

    A runaway order must be loud: this is the only signal that a purchase was
    abandoned mid-flight for spending too much, and the number in it is what
    tells us whether the ceiling is set right.
    """
    logger.warning("order budget breach order_id=%s %s", order_id, verdict.detail)
    with sentry_sdk.new_scope() as scope:
        scope.set_context(
            "order_budget",
            {
                "order_id": str(order_id),
                "reason": verdict.reason,
                "cumulative_cost_cents": verdict.spent_cents,
                "spend_ceiling_cents": verdict.ceiling_cents,
                "attempts": verdict.attempts,
                "attempt_budget": verdict.attempt_budget,
            },
        )
        if step_log_tail is not None:
            scope.set_context("step_log_tail", {"steps": list(step_log_tail)})
        sentry_sdk.capture_message(
            f"order {order_id} cut off by {verdict.reason}: {verdict.detail}",
            level="error",
        )
