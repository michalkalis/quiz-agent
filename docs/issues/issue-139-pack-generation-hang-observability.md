# Issue 139: Pack generation hangs silently → order force-failed with zero diagnostics

**Triage:** bug · ready-for-agent
**Reversibility:** a
**Status:** Root-caused to the failure *mode* 2026-08-04 (read-only prod inspection); the underlying trigger (OOM vs hung LLM call) is unproven — fixing observability is the point.
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

**Memory finding (acceptance 4):** worker RSS at run start 216–219 MB of 512 MB (~43%) across sourcing/generating stage starts — no OOM implication; no machine action needed. Per-stage RSS keeps logging on every run for future regressions.

## Acceptance

- [ ] Every pipeline stage LLM/network call carries an explicit timeout (grep/test evidence per stage; a stubbed hanging call fails the stage with a logged exception, pytest).
- [ ] Worker runs with Sentry enabled; a forced test failure from the worker appears in Sentry (verified via /check-crashes or Sentry API) with step context.
- [ ] Sweep force-fail emits a Sentry event (pytest on the emit path + one real verification).
- [ ] Memory finding recorded in this file (number + disposition); action taken if >~80% of 512MB.
- [ ] Founder's order `7dbef479…` retried post-deploy and reaches `delivered` (prod check), or the retry's failure reason is now concretely visible in Sentry — either outcome fails loud, not silent.
- [ ] quiz-pack-api suite green (`LLM_GATEWAY=direct` pinned per test-gate memory); deployed to prod (autonomous per Rule 8).
