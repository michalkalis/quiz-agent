# Issue 150: Pack pipeline per-question stages block and serialize the worker loop, defeating the hang-protection layers

**Triage:** bug · needs-triage
**Priority:** serious
**Source:** architectural audit 2026-08-06
**Reversibility:** a
**Created:** 2026-08-06

## Context

A pack order is the only paid path in the product: the founder buys a pack, one worker job runs the whole orchestrator pipeline, and every stage sits under the 1200s stage belt added by #139 — pack generation hang observability. Two per-question stages in `apps/quiz-pack-api` do their work the slow way while their immediate neighbours (answerability, scoring) already run bounded-concurrent: dedup blocks the worker's event loop entirely, and fact verification awaits one question at a time. The first makes #139's hang protection inert on that stage (timeouts and heartbeat cannot fire while the loop is blocked, which re-opens the double-enqueue the sweep exists to prevent); the second makes verification the pipeline's dominant wall-clock cost, so a slow provider day can burn the belt and discard a paid order after all sourcing/generation spend. Both live in the same pipeline, take the same fix pattern (async store / bounded concurrency) and share one verification run, so they are one workstream.

## Confirmed findings

Both findings were independently re-verified against the code (adversarial pass, 2026-08-06); line numbers below re-checked while writing this plan.

### 1. Dedup is a synchronous island in an async pipeline — `app/orchestrator/stages/dedup.py:111`

`DedupStage.run` is `async`, but its per-question loop (dedup.py:81-101) contains no `await` at all: for each question it calls the **sync** `self._store.find_duplicates(question.question, threshold=...)` (dedup.py:111). In the worker that store is a `SyncPgvectorStore` (`app/worker/worker.py:118`), whose bridge is `future = asyncio.run_coroutine_threadsafe(coro, loop); return future.result()` — **no timeout** (`packages/shared/quiz_shared/database/sync_pgvector_store.py:57-60`) — fronting a sync OpenAI embeddings HTTP call (`pgvector_client.py:283` → `utils/embeddings.py:50`) and an asyncpg query on a bridge engine created with no `command_timeout` (worker.py:112-117).

While that thread is blocked, nothing else on the worker loop runs: not the 60s `_job_heartbeat` tick (`app/worker/tasks.py:54-68`, started at tasks.py:155), not the sweep cron, and not the belts. `asyncio.wait_for(stage.run(...), timeout=_STAGE_TIMEOUT_SECONDS)` (`app/orchestrator/pack_generator.py:154`) and ARQ's `job_timeout=3600` are both **cancellation-based**, and cancellation cannot be delivered to a blocked thread. The comment right above that `wait_for` already names this exact hole ("wait_for relies on cancellation, so a cancel-immune hang — e.g. a stuck sync bridge thread — still needs the per-call timeouts"), but this path was never converted. Dedup also re-runs on the *merged* list in every top-up round (`app/orchestrator/stages/topup.py:99`), so a pack_30 pays roughly 90 serialized blocking embedding calls per order.

**Impact.** This is the one place in the pipeline where #139's hang-protection architecture is inert. A slow or retrying embeddings endpoint freezes the whole worker (both `max_jobs` slots) with no timeout able to fire and no heartbeat; when the loop resumes, the sweep can see a stale `job.updated_at` and re-enqueue a job that is still running — a second paid pipeline for one purchase, exactly the double-billing the heartbeat was added to prevent. Every future hang investigation here will re-derive this, and it gets harder to fix as more stages lean on the sync `QuestionStore` protocol.

**Calibration note (why serious, not critical).** The embedding leg *is* bounded: `factory.openai_client` defaults to `DEFAULT_TIMEOUT = httpx.Timeout(30.0, connect=5.0)` (`factory.py:59,239`), so a degraded embeddings endpoint blocks ~30s × SDK retries per question (exception then swallowed at dedup.py:114-117), not forever. The unbounded leg is the DB/bridge call. Normal-path blockage is on the order of seconds per pack — a real architectural defect with a bounded dominant failure mode.

### 2. Fact verification is strictly sequential while its siblings are concurrent — `app/verification/fact_verifier.py:342`

`verify_batch` is a bare `for q in questions: result = await self.verify(...)` (fact_verifier.py:342-346, re-verified after the 2026-08-06 config-switchable-models commit `a86a30ea` — the loop survived the refactor) — no gather, no semaphore, no chunking. Each `verify` awaits one Tavily search (`_TAVILY_TIMEOUT_SECONDS = 10.0`, `app/sources/web_search_source.py:19`) and, on any inconclusive verdict, an LLM arbitration call routed through the single `_complete` boundary (fact_verifier.py:133, client built by `llm_factory` with generation-class timeout). Its only live caller, `VerificationStage.run` (`app/orchestrator/stages/verification.py:90`), adds no concurrency of its own — and its logical-verifier branch (verification.py:92-96) is a second sequential per-question `await` loop.

Both neighbours do the opposite: `MultiModelScorer.score_batch` gathers under `asyncio.Semaphore(_MAX_CONCURRENT_CALLS)` (`app/scoring/multi_model_scorer.py:851,864` — note the file lives under `app/scoring/`, not `app/verification/`), and `AnswerabilityStage` uses the same pattern (`app/orchestrator/stages/answerability.py:38,44`). Verification is the sole per-question stage still serialized, so this is an outlier against two in-repo precedents, not a house style; nothing in `web_search_source.py` documents a rate-limit reason for it.

**Impact.** Verification wall-clock scales linearly with question count while everything adjacent scales with the panel budget. `_STAGE_TIMEOUT_SECONDS = 1200` (`pack_generator.py:41`) was sized for the *generating* stage worst case, and `TopUpStage` is itself one stage that re-runs generation + dedup + answerability + verification + scoring for up to `_max_rounds` (topup.py:84-112) — all inside a single `wait_for`. A handful of pathological questions (10s Tavily + a 300s arbiter each) can alone cross the belt, at which point `PackGenerator` fails the stage and the order is discarded after all prior spend (pack_30 ≈ $4.23 per #139 / #143 — pack COGS plan) and re-run from zero.

**Calibration note.** The belt crossing is a plausible worst case, not an observed one; typical Tavily + arbiter latency should land well under 1200s, and the arbiter runs the cheaper VERIFY role. What is confirmed today is the concurrency asymmetry and its latency shape.

*No unverified/minor findings in this issue — both items carry an adversarial CONFIRMED verdict.*

## Proposed approach

1. **Take dedup off the blocking bridge.** Give `DedupStage` the async question store directly and `await find_duplicates`, keeping `SyncPgvectorStore` only for the genuinely sync quiz-agent read path. If the sync protocol must stay for now, the fallback is to run the bridge call off-loop (`asyncio.to_thread`) *and* give the bridge a bounded `future.result(timeout=...)` so a stuck bridge fails loud instead of freezing the worker — but the async store is the correct end state, and the fallback should be marked as such.
2. **While in that file, bound the bridge itself.** The no-timeout `future.result()` in `sync_pgvector_store.py` is a hazard for any caller; a default timeout there is cheap and turns a freeze into an exception.
3. **Make verification concurrent like its siblings.** Mirror `score_batch`: gather over questions under a semaphore sized to provider limits, in both `verify_batch` and the logical-verifier branch of `VerificationStage`. Reuse the existing env-driven concurrency-knob convention rather than inventing a new one.
4. **Do not change models, prompts, thresholds or verdict semantics.** This is a concurrency-shape change only; question outcomes must be identical to today (dedup drops the same questions, verification returns the same verdicts, only faster and non-blocking).
5. **Verify on one real pack_30 order** end-to-end after deploy, watching the step log for stage durations and the heartbeat ticking during dedup.

## Done criteria

- [ ] No stage in the worker pipeline performs a blocking call on the event loop: `DedupStage` awaits the store (or runs the bridge via `to_thread` with a bounded result wait), and a test asserts the loop stays responsive — e.g. a heartbeat-style task keeps ticking while a deliberately slow dedup store call is in flight.
- [ ] A hung dedup store call now fails loud within a bounded time (test: patched store that never returns → stage raises a timeout error, order fails with a named stage, instead of hanging).
- [ ] `SyncPgvectorStore.run` no longer waits without a timeout; default is explicit and documented.
- [ ] `FactVerifier.verify_batch` and the logical branch of `VerificationStage` run concurrently under a semaphore; a test with N slow stubbed verifications completes in roughly one round-trip, not N, and returns results in the same order/content as the sequential version.
- [ ] Verdict/drop parity: existing dedup and verification tests pass unchanged (no threshold or semantics drift), quiz-pack-api suite green with `LLM_GATEWAY=direct` pinned, verified twice per the test-gate rule.
- [ ] One real pack_30 order runs post-deploy: step log shows heartbeat updates continuing through the dedup stage, and the verification stage duration is materially below the sequential baseline recorded in the same log.
- [ ] `docs/issues/INDEX.md` and `docs/todo/TODO.md` updated with the issue and its outcome.
