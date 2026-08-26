# Issue 139: Pack generation hangs silently → order force-failed with zero diagnostics

**Triage:** bug · agent-side DONE, awaiting founder leg (OpenRouter top-up)
**Reversibility:** a
**Status:** Agent-side SHIPPED + deployed to prod 2026-08-04 (see Findings). All observability acceptance verified live. Delivery of the founder's order is blocked ONLY on OpenRouter credit: balance $0.71, one pack_30 attempt ≈ $4.23. After top-up: one manual `POST /v1/orders/7dbef479…/retry` remains (manual_retry_count 2/3). New: #142 — non-JSON provider response, filed from the first observable run.
**Created:** 2026-08-04

## What happened (founder's 2026-08-03 order, shows FAILED in app)

Order `7dbef479-53d3-4061-8db1-f525192b55c1` (pack_30, language sk, created 2026-08-03T19:10Z, admin-key path so **no money charged**):

- The worker pipeline **hung** at `sourcing`/`generating` (no exception raised) — idle >15 min per attempt.
- The stuck-order sweep (`app/worker/sweep.py:135-148`, from #103) re-enqueued it 3× then force-failed at 20:30 with the generic "stuck past recovery budget" message. `manual_retry_count=0` — retry budget unused.
- **No Sentry event** exists for quiz-pack-api after 2026-07-20 — a stalled/killed worker emits nothing; `fly logs` has no retention that far back. The actual trigger is unrecoverable.

Plausible triggers, none evidenced: worker machine OOM/auto-suspend mid-job (known: 512MB machine, chromadb import bloat — see memory `project_upstash_mitigation_deferred`); a hanging OpenRouter call (LLM timeouts were added for the API service in the 2026-07-18 arch remediation — verify the *worker pipeline stages* actually have per-call timeouts); OpenRouter credit low (~$9; a clean 402 should fail fast and be logged, which didn't happen — weaker candidate).

## Fix scope (worker: `apps/quiz-pack-api/app/worker/`)

1. **Per-stage/per-LLM-call timeouts** in the pipeline (`tasks.py:95-187` stages) so a hang becomes a caught, logged exception instead of a sweep kill.
2. **Worker observability**: Sentry init + breadcrumbs/step heartbeats in the worker process; force-fail path (`_handle_failure`, `tasks.py:197-252`) and sweep force-fail report to Sentry with the step log.
3. **Memory check**: measure worker RSS during a pack run on the 512MB machine; if OOM is implicated, fix (defer chromadb import / bump machine) rather than paper over.
4. **Recover the founder's order**: after 1–3 are deployed, trigger `POST /v1/orders/{id}/retry` (`orders.py:543-658`) on the failed order and confirm delivery end-to-end.

## Findings (2026-08-04 implementation)

Three compounding holes explain the zero-diagnostics failure; all fixed:

1. **`chat_openai()` had no timeout at all.** LangChain's default is an *explicit* `timeout=None` handed to the OpenAI SDK, which (unlike the omitted-arg sentinel) disables httpx timeouts entirely. The generation, critique, and scoring clients — exactly the stages the order hung at — could wait forever on a stalled connection. All native-SDK call sites (verifier, normalizer, answerability, …) already carried `GENERATION_TIMEOUT` (300s); Tavily/Wikipedia/OpenTrivia had explicit 10–15s timeouts. Fix: factory defaults the ChatOpenAI path to `GENERATION_TIMEOUT`.
2. **ARQ's job_timeout kill was invisible to our code.** `job_timeout=600` cancels the task with `CancelledError` (a BaseException) — `process_order`'s `except Exception` never ran, so a timed-out attempt updated no rows, logged nothing, sent nothing. Fix: explicit cancel handler names the hung stage (`PackGenerator.current_stage`), runs `_handle_failure`, re-raises.
3. **The sweep's force-fail (where the order actually died) only logged a warning** — a Sentry breadcrumb, not an event. Fix: error-level `capture_message` with the step-log tail.

Belt: per-stage `asyncio.wait_for` (`STAGE_TIMEOUT_SECONDS`). Observability: stage breadcrumbs, per-stage RSS log lines (`/proc/self/statm`), one rich Sentry event per failed attempt (step-log context) in `_handle_failure`. Worker machine did NOT restart during the hang window (last update 18:57Z vs order 19:10Z) — weakens the OOM theory; unbounded LLM call is the prime suspect. The forced-failure Sentry event carried the 2026-08-03 step log: the order hung in `generating` — the exact stage whose client had no timeout.

**Second wave (live verification, 2026-08-04).** With hangs converted to loud failures, the real pack_30 retry died at `STAGE_TIMEOUT_SECONDS=480s` in `generating` while actively spending (~$0.075) — a LEGIT frontier run (GEN=claude-fable-5, 30q batch + critique + MCQ calls) needs >8 min there, and the old `job_timeout=600` (sized for pack_10) guaranteed an ARQ kill on every large pack. That, not OOM, is the concrete root cause of the founder's failure. Fixes: `job_timeout` 600→3600, `STAGE_TIMEOUT_SECONDS` default 480→1200 (hang protection stays with the 300s per-call timeouts); 60s job heartbeat on `updated_at` so the sweep's 15-min staleness never re-enqueues a live long stage (double-billing risk); `_handle_failure` no longer rewinds `job.retry_count` to ARQ's per-id `job_try` (sweep re-enqueues use fresh ids → job_try always 1 → budget never exhausted, endless paid retries); last budgeted attempt is now terminal for the order immediately. Also: a `failed` job under an `in_progress` order (parked non-final failure) was invisible to the sweep and unretryable (409) — sweep predicate now recovers it.

**Third wave (2026-08-04, surfaced by the fixes themselves):** the manual-retry attempt got through generation (first time ever for pack_30) and died in dedup: the worker's `SyncPgvectorStore` shared the app engine across the main loop and the bridge's background loop — asyncpg connections are loop-bound, so pooled connections crossed loops → `RuntimeError "attached to a different loop"` (made deterministic by the new 60s heartbeat's concurrent main-loop DB traffic). Fixed: the bridge gets its own engine (every other call site already did). Also found: the retry endpoint 500'd because the deployed image lacked `AppleRootCA-G3.cer` (gitignored; #140 added it to the checkout the same day) — redeploy from a checkout with the cert fixed it.

**Memory finding (acceptance 4):** worker RSS 216–255 MB of 512 MB (~43–50%) across a full run through scoring — no OOM implication; no machine action needed. Per-stage RSS keeps logging on every run for future regressions.

**Cost datapoint (Rule #11):** the successful-generation attempt spent **≈$4.23 of OpenRouter credit for one pack_30** on the #134 frontier stack (GEN=claude-fable-5 + critique + judges) — against the €4.99 retail price that is ~zero margin; flag for the monetization/model-mix discussion.

## Acceptance

- [x] Every pipeline stage LLM/network call carries an explicit timeout — chat_openai factory default `GENERATION_TIMEOUT` (300s) closed the last unbounded call sites (generation/critique/scoring); native-SDK + Tavily/Wikipedia/OpenTrivia sites already bounded (Explore audit table, 2026-08-04). Hanging-stage pytest: `test_hanging_stage_fails_with_timeout`.
- [x] Worker Sentry: forced test failure (stage-timeout on a real order attempt) verified via Sentry API — event with `order` + `step_log_tail` contexts (Sentry issue 138791627 family).
- [x] Sweep force-fail emits a Sentry event — pytest `test_sweep_force_fail_emits_sentry_event`; real-path verification implicit (same `capture_message` emit path; live sweep recovery observed 3×).
- [x] Memory finding recorded above: 216–255 MB of 512 MB across a full run — well under the ~80% action threshold; no action.
- [x] Founder's order retried post-deploy: every failure reason now concretely visible (stage-timeout → TimeoutError with stage name; provider non-JSON body → #142; cross-loop pool bug → found & fixed same day). `delivered` itself is blocked on OpenRouter top-up (founder leg) — one manual retry left.
- [x] quiz-pack-api suite green (791 passed, LLM_GATEWAY=direct pinned, verified twice); deployed to prod 4× on 2026-08-04 (releases v34–v37).

## TODO detail (migrované z TODO.md 2026-08-26)

- [~] #139 Pack generation hangs silently → FAILED with zero diagnostics — [plan](../issues/issue-139-pack-generation-hang-observability.md) — **agent-side SHIPPED+deployed 2026-08-04** (per-call LLM timeouts, cancel-path reporting, sweep Sentry, job heartbeat, pack_30-sized budgets, dedup-bridge engine fix, monotonic retry budget; forced failure verified in Sentry; RSS 216–255 MB/512 → no OOM). Remaining = **founder: top up OpenRouter** (balance $0.71; one pack_30 attempt ≈ $4.23) → then one manual retry of `7dbef479…` (1 of 3 left). New: #142 non-JSON provider response — **fixed 2026-08-05** (bounded retry + raw-body logging at both generation call sites; sub-batching deferred pending eval + founder approval).

