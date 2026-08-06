# Issue 145: Manual retry resets the ARQ attempt budget — one purchase can drive ~12 full frontier pipeline runs with no spend ceiling

**Triage:** bug · needs-triage
**Priority:** serious
**Source:** architectural audit 2026-08-06
**Reversibility:** a
**Created:** 2026-08-06

## Context

A paid pack order runs the full frontier generation pipeline (sourcing → generation → critique → judge panel), measured at **≈$4.23 per pack_30 run** (#139 — pack generation hang observability, cost datapoint). Retries exist for good reasons — the sweep recovers hung workers, and `/retry` lets a customer re-run a failed order — but nothing in the order/job layer knows how much money an order has already burned. Because the manual retry endpoint zeroes the auto-attempt counter, a single purchase can legitimately walk through four independent 3-attempt budgets, and the code that records cost only fires on success, so those runs leave no financial trace at all. This is a pre-GA money hole: it must be closed before the paid pack path goes live, while prod still has no real users.

## Confirmed findings

### F1 — `/retry` restores the full auto-retry budget; up to ~12 paid pipeline runs per purchase (verified, serious)

`apps/quiz-pack-api/app/api/v1/orders.py:629-651` — `retry_order` refuses only at the manual cap, then wipes the auto counter:

```
if job.manual_retry_count >= 3:      # orders.py:629
    ...422...
job.status = "queued"
job.progress = 0
job.error = None
job.retry_count = 0                  # orders.py:641
job.manual_retry_count = job.manual_retry_count + 1   # orders.py:642
```

The auto budget it zeroes is shared, not per-endpoint:

- `apps/quiz-pack-api/app/worker/worker.py:157` — `max_tries: int = 3`.
- `apps/quiz-pack-api/app/worker/sweep.py:143` — `_recover_stuck_order` re-enqueues while `job.retry_count >= max_tries` is false, incrementing at `sweep.py:183`, and only force-fails the order once the budget is exhausted. Its predicate deliberately includes a `failed` job under an `in_progress` order (`sweep.py:81-87`), so ordinary exception failures — not only hangs — flow through this recovery loop.
- `apps/quiz-pack-api/app/worker/tasks.py:282-286` — `effective_try = max(job.retry_count, job_try)`. That `max()` was the #139 fix for the *sweep* rewinding the counter; it does nothing here, because a manual retry zeroes `retry_count` **and** enqueues under a fresh ARQ id (`attempt_job_id`, `apps/quiz-pack-api/app/db/models/job.py:108-119`), so `job_try` also restarts at 1. Both sides of the `max()` are back at the start.

Net: 1 initial sequence + 3 manual retries × 3 auto attempts each = **up to ~12 full pipeline runs for one purchase**. There is no resume or checkpointing in `pack_generator` — every attempt reruns sourcing, generation and judging from scratch — and no spend budget anywhere in `app/orchestrator` or config (the #139 "pack_30 budgets" are stage *timeouts*, not money).

**Impact.** A pack that fails late (e.g. in the judge panel) can burn on the order of a dozen frontier runs (~$4.23 each measured) against a single ~€4.99 purchase — a two-orders-of-magnitude gap between price and worst-case cost. The exposure is bounded, not open-ended: it needs repeated late-stage failures plus an explicit user action per extra sequence. It stays *serious* rather than critical for that reason, but it is cheap to close now and expensive to discover after GA.

### F2 — Cumulative spend is not recorded, so no ceiling is currently enforceable (verified as part of F1's mechanism)

`apps/quiz-pack-api/app/worker/tasks.py:205` — `job.total_cost_cents = cost_cents` is an **assignment on the success path only**. A failed attempt records nothing, and a later attempt overwrites rather than accumulates. So even if a ceiling were added today there is no number to check it against, and the ~12-run worst case above is invisible in the data.

The general cost-on-failure plumbing (recording spend for attempts that fail) is filed separately as a small finding in the audit collector; this issue depends on it and should land with it.

### Not duplicates

`docs/issues/INDEX.md`: #139 — pack generation hang observability covers the monotonic *sweep* budget; #143 — pack COGS covers per-run cost measurement; #142 — pack_30 non-JSON provider response covers the JSON-parse retry. None caps cumulative per-order spend across manual retries.

## Proposed approach

Treat one purchase as one spend envelope, not as a series of independent attempt budgets. Conceptually, three moves in the order/job layer:

1. **Stop conflating "which ARQ sequence is this" with "how many attempts has this order had."** The manual retry endpoint currently zeroes the auto counter purely so the deterministic ARQ job id stays unique across sequences (see the `attempt_job_id` docstring). Give the job id its own monotonic sequence number and leave the attempt counter alone, so `retry_count` becomes a true lifetime attempt count for the order.
2. **Accumulate spend per order, on every attempt — success or failure.** Cost recorded only on delivery is the reason the hole is invisible; the accumulator is the prerequisite for any ceiling.
3. **Gate both retry paths on a cumulative ceiling derived from the product tier.** The ceiling should be configuration, expressed as a multiple of the tier's measured COGS, and it should be checked in one place that both `retry_order` and the sweep's recovery path consult — not duplicated. Hitting the ceiling is a terminal, refund-eligible failure with a distinct error and a Sentry event, so a runaway order is loud rather than silent.

Keep the existing manual cap of 3 as a secondary guard; the spend ceiling is expected to bind first on expensive tiers and the attempt cap on cheap ones.

## Done criteria

- [ ] `retry_order` no longer writes `job.retry_count = 0`; the ARQ job id stays unique across manual retries via its own sequence field. Test: three consecutive manual retries produce three distinct ARQ job ids **and** a strictly increasing `retry_count`.
- [ ] Total attempts across one order's whole lifetime cannot exceed the configured budget. Test: an order that fails on every attempt reaches a terminal `failed` state after the lifetime budget, not after 4 independent budgets.
- [ ] Per-order cumulative spend is persisted and increases on **failed** attempts, not only delivered ones. Test: an attempt that fails after the generation stage leaves a non-zero cumulative spend on the order.
- [ ] A retry that would exceed the tier's spend ceiling is refused: `retry_order` returns a 4xx naming the ceiling, and the sweep's recovery path force-fails the order instead of re-enqueuing. Both paths consult one shared check.
- [ ] Crossing the ceiling emits an error-level Sentry event carrying order id, cumulative spend and attempt count, and marks the order refund-eligible.
- [ ] Ceiling is configurable per product tier and defaults to a value grounded in the measured pack COGS (#143), not a magic number in code.
- [ ] quiz-pack-api suite green with `LLM_GATEWAY=direct` pinned, verified twice (per `project_test_gate_env_hermeticity`).
