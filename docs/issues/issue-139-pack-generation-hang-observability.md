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

## Acceptance

- [ ] Every pipeline stage LLM/network call carries an explicit timeout (grep/test evidence per stage; a stubbed hanging call fails the stage with a logged exception, pytest).
- [ ] Worker runs with Sentry enabled; a forced test failure from the worker appears in Sentry (verified via /check-crashes or Sentry API) with step context.
- [ ] Sweep force-fail emits a Sentry event (pytest on the emit path + one real verification).
- [ ] Memory finding recorded in this file (number + disposition); action taken if >~80% of 512MB.
- [ ] Founder's order `7dbef479…` retried post-deploy and reaches `delivered` (prod check), or the retry's failure reason is now concretely visible in Sentry — either outcome fails loud, not silent.
- [ ] quiz-pack-api suite green (`LLM_GATEWAY=direct` pinned per test-gate memory); deployed to prod (autonomous per Rule 8).
