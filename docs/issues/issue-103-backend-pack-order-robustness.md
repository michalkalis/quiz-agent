# #103 — Custom-pack order robustness (before packs go paid)

**Triage:** bug · done
**Status:** **DONE 2026-07-17** — all 6 findings fixed via workflow (3 worktree branches, adversarial review, 0 fix rounds), merged to main. Suites: quiz-pack-api 626 passed / 3 xfailed, quiz-agent 411 passed, iOS targeted (PackOrderService/OrderPackViewModel/PackOrderCodable) green. Notable implementation choices: `manual_retry_count` column (migration `9c1a2f6e5b3d`); stuck-order sweep = ARQ cron every 5 min (pending >3 min, in_progress >15 min); TopUpStage floor = 80 % of target, max 2 top-up rounds; StoreKit = hardened offline chain walk (Option B — Apple lib rejected for online OCSP on hot path). **Prod deploy of quiz-pack-api NOT done** (new migration + newly-mandatory bearer on order creation → founder call). Original plan below.
Planned 2026-07-16 from the pre-MVP review (quiz-pack-api pipeline + seam findings). **Not a friends-launch blocker** — custom packs are admin-key/founder-only today, no StoreKit charge — but every finding here becomes "money taken, no pack, no recovery" the moment packs become a paid product. Fix before that switch. Both backend test suites are green today (quiz-pack-api 606 passed / 3 xfailed); these are logic gaps the tests don't exercise.

## 1. Findings (confirmed, file:line + fix)

| # | Sev | Defect | Evidence | Fix |
|---|-----|--------|----------|-----|
| 1 | P1 | **The manual retry endpoint can never run for a genuinely failed order** — the only user-facing recovery is dead on arrival | `app/worker/tasks.py:191` sets `job.retry_count = job_try`; an order reaches `failed` only on the final ARQ attempt (`job_try >= max_tries=3`), so every failed order has `retry_count == 3`; `app/api/v1/orders.py:443` returns 422 when `retry_count >= 3`. The passing retry test hand-forces `retry_count=0`, a state the runtime never produces. | Reset `job.retry_count` to 0 when the order enters terminal `failed`, or track auto-retries separately from the manual-retry budget. |
| 2 | P1 | **Incomplete StoreKit JWS chain validation** — only anti-forgery control for paid packs | `app/storekit/verifier.py:161-203` `_verify_chain` checks validity dates + issuer-name + signature, but **not** Basic Constraints (`CA:TRUE`), key-usage/EKU, or path length. An attacker holding any non-CA leaf whose key they control that chains to Apple Root CA G3 (plausible via a $99 developer cert) could sign a forged leaf the verifier accepts. ES256 pinning + root anchoring + bundleId/env/expiry checks are correct. | Replace the hand-rolled walk with Apple's `app-store-server-library`, or enforce RFC 5280 (CA:TRUE on issuers, leaf EKU, path length). |
| 3 | P1 | **Order created without the account bearer orphans a generated pack** — unplayable + unlistable, LLM cost spent | `app/api/v1/orders.py:163` uses `optional_user` → bearer-less create writes `GenerationOrder.user_id=NULL` → `app/orchestrator/stages/persist.py:66` copies `question_packs.user_id=NULL`; `apps/quiz-agent/app/api/routes/sessions.py:56-69` `_require_pack_ownership` needs `user_id = :subject_id` (NULL never matches → 404), and `list_orders` never shows it. iOS attaches the bearer only opportunistically (`Services/PackOrderService.swift:121-131`). | Make the account bearer mandatory for order creation, or add an owner-claim/backfill path for `user_id IS NULL` packs. |
| 4 | P1 | **Orders can lodge in a non-terminal state forever** — no reaper, `refund_eligible` never read | `app/api/v1/orders.py:246-249` commits the order `pending` *before* `enqueue_job` (249); if enqueue raises (Redis blip / worker asleep) the order is stuck `pending` — replay returns it without re-enqueuing, retry needs `failed` (409). A hard-killed worker leaves it stuck `in_progress`. `refund_eligible` is written (`tasks.py:194`) but has zero readers and there's no sweep. | Roll back / mark retryable on enqueue failure; add a sweep that re-enqueues or fails orders stuck past a timeout; actually consume `refund_eligible`. |
| 5 | P1 | **Pack delivered with fewer questions than paid for, silently** | best-of-N returns at most `count`; `GenerationStage`/`ScoringStage`/`DedupStage` drop more with **no top-up loop**; `app/orchestrator/stages/persist.py:72` writes `actual_count=len(survivors)`, `app/worker/tasks.py:131` marks `delivered` unconditionally, and `actual_count` isn't in `OrderSnapshotResponse` so the client can't detect the shortfall. *(agent-reported anchors — verify.)* | Over-generate a buffer + backfill to `target_count` (or fail below a floor) before `delivered`; expose `actual_count`. |
| 6 | P2 | **Client idempotency key is random per call** → duplicate paid order + double generation on a retry | `apps/ios-app/Hangs/Hangs/Services/PackOrderService.swift:53-67` mints `admin-{UUID()}` on every `createOrder`, so the server's `transaction_id` dedup (`orders.py:211-222`) never triggers on a network-timeout retry; no in-flight submit guard either. Admin-path only today; a genuine double-charge risk once packs carry a real StoreKit txn id. | Key idempotency to a stable id (the real StoreKit transaction id once paid); persist it per order intent; guard submit against re-entry. |

## 2. Plan

Backend sweep (findings 1–5) + the one iOS client fix (6). Findings 2 (chain validation) and 3/4 (money-with-no-pack) are the priority — they are the "paid, nothing exists" paths. Gate each with a test that reproduces the bad state (a failed order that *can* be retried; a sandbox/forged JWS rejected; a bearer-less create refused; a stuck order swept; a short pack topped-up or failed).

## 3. Acceptance

- A genuinely failed order can be retried via the API (test: drive to terminal `failed`, retry succeeds).
- Chain validation rejects a leaf that chains to the root but lacks CA constraints (test with a crafted chain, or the official library's own tests).
- Bearer-less order creation is refused or the pack is claimable (no NULL-owner orphans).
- A stuck `pending`/`in_progress` order is recovered by the sweep.
- A pack never reaches `delivered` below its question floor without surfacing the shortfall.
- quiz-pack-api suite green (currently 606 passed / 3 xfailed).

## 4. Out of scope

iOS purchase recovery (#102), environment separation (#101), driving-loop (#100), offline generation scripts, question content quality (#72/#99).
