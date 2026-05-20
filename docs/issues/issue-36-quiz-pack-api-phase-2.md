# Issue 36: quiz-pack-api Phase 2 — `PackGenerator` orchestrator + voice-quiz pgvector cutover

**Triage:** enhancement · ready-for-agent
**Status:** Plan locked 2026-05-20 from #32 §3 Phase 2 scope + open gaps (F1, F8, M-2, voice-quiz cutover per §2.4.1). Atomic `- [ ]` tasks ready for Ralph autonomous burndown.
**Created:** 2026-05-20
**Parent:** #32 (umbrella strategy) · predecessor #33 (Phase 1 — code-complete 2026-05-15)

> Issue-number note. #32 §5 forecast Phase 2 → #35, but #35 was claimed by the parallel-backlog-burndown work on 2026-05-15. Phase 2 lands at #36 (next free); downstream phases shift one number per #32 §5 forecast (Phase 3 → #37, Phase 4a → #38, Phase 4b → #39, Phase 5 → #40, Phase 6 → #41).

---

## Phase 2 scope

**In** (from #32 §3 + open gaps with `Candidate: Phase 2`):

- Build a canonical `PackGenerator` orchestrator that walks an order through `sourcing → generating → critiquing → verifying → scoring → dedup → persisting → done` with progress events. (#32 F1, F2)
- Wrap `FactSourcer`, `AdvancedQuestionGenerator`, `FactVerifier`, `MultiModelScorer` as composable `Stage` objects with a single `ProgressSink` writing `step_log` + Redis pubsub.
- Replace the Phase 1 stub `process_order` body with a real `PackGenerator.run(order)`. The pubsub / `step_log` contract from #33 task 1.10 is preserved verbatim.
- Delete duplicate generator paths: basic `QuestionGenerator` (U1), `/api/v1/export/chatgpt` + `build_for_chatgpt` (U2), `czech_slovak_source.py` (U5), `news_source.py` (U4), `scripts/generate_questions_claude.py`, `scripts/generation_worker.py`.
- Rewrite the `/generate-questions` skill + admin scripts as thin clients of `PackGenerator` (one CLI entrypoint, no reimplemented pipelines).
- **F8 source quality**: every `PackGenerator` run must traverse `SourcingStage` — no path that lets the LLM hallucinate `source_url` / `source_excerpt`.
- **M-2 retry**: `POST /v1/orders/{id}/retry` requeues a `failed` order when `retry_count < 3`.
- **Voice-quiz read-path cutover to pgvector** (#32 §2.4.1). `apps/quiz-agent/app/retrieval/question_retriever.py` swaps its `ChromaDBClient` default for a new `PgvectorQuestionStore`. ChromaDB volume becomes read-only until Phase 6 retires it.

**Out (deferred, with target phase in parens):**

- OpenAI Moderation on input + output, topic safety, prompt caching, fact-pool cache (D5/C3), per-tier cost cap, stuck-job reconciler — Phase 3 (#37).
- iOS integration, non-consumable purchase flow, SSE progress UI, language confirmation modal, `Transaction.beginRefundRequest` — Phase 4a (#38).
- Subscription, ASSN V2 webhook, entitlement state machine, server-side stable `user_id` migration — Phase 4b (#39).
- Langfuse traces, DeepEval CI gate, Sentry on quiz-pack-api — Phase 5 (#40).
- ChromaDB volume decommission, JSON-on-disk artifact cleanup, admin UI behind `/admin` — Phase 6 (#41).
- **D3 cross-lingual reuse mechanism (#32 open gap).** Consumption-time aliasing for `language_dependent=false` questions has no concrete design yet. Deliberately deferred to Phase 4a where the iOS language modal forces the design conversation, or a follow-up mini-issue if it surfaces earlier. Phase 2 does *not* address this.

---

## Decisions referenced (no new decisions — all locked in #32 §4 / #33 revisions)

- **C1 storage**: pgvector is the canonical question + pack embedding store. ChromaDB is read-only after this phase.
- **C2 subscription split**: Phase 2 stays non-consumable-only.
- **C3 cache**: fact-pool caching is deferred to Phase 3 — `PackGenerator` is built without the cache hook so Phase 3 can add it as an optional pre-stage.
- **D6 worker**: single Fly app, web + worker process groups (established in #33 task 1.10).
- **D7 global library**: existing curated content keeps `pack_id=NULL`. Generated packs are additive.

---

## Architecture (Phase 2 target)

```
                                 ┌──────────────────────────────────────────┐
ARQ worker (Phase 1 scaffold)    │   PackGenerator.run(order)               │
  process_order(ctx, order_id) ──┤                                          │
                                 │   stages = [                             │
                                 │     SourcingStage(FactSourcer),          │
                                 │     GenerationStage(AdvGenerator),       │
                                 │     # critique is inside generation —    │
                                 │     # best-of-N + LLM judge are coupled  │
                                 │     VerificationStage(FactVerifier),     │
                                 │     ScoringStage(MultiModelScorer),      │
                                 │     DedupStage(PgvectorStore + Jaccard), │
                                 │     PersistStage(PgvectorStore + Pg),    │
                                 │   ]                                      │
                                 │   for stage in stages:                   │
                                 │     progress_sink.start_step(...)        │
                                 │     result = await stage.run(ctx, sink)  │
                                 │     progress_sink.finish_step(...)       │
                                 │     ctx.merge(result)                    │
                                 └──────────────────────────────────────────┘
                                                  │
                                                  ▼
                          DBProgressSink ─── append_step (one SQL UPDATE) ──▶ Postgres step_log
                                       └─── redis.publish ─────────────────▶ order:{id}:progress

apps/quiz-agent (voice quiz) ──── QuestionRetriever(PgvectorQuestionStore) ──▶ Postgres+pgvector
                                  (read path cutover — ChromaDB read-only)
```

Storage layout is unchanged from Phase 1. Phase 2 only changes who *writes* (PackGenerator instead of stub) and who *reads* on the voice-quiz side (pgvector instead of ChromaDB).

---

## Tasks (atomic, Ralph-ordered)

Each task is one Ralph iteration: scoped to ~15 min, one commit, clear acceptance check. Tasks are ordered by dependency — do not pick out of order unless the predecessor was a no-op (see "Sequencing" below).

### Phase 2A — Orchestrator scaffold

- [x] **2.1 Module skeleton + interfaces.** Create `apps/quiz-pack-api/app/orchestrator/{__init__.py, pack_generator.py, progress_sink.py, context.py, stages/__init__.py}`. Define the `Stage` Protocol (`name: str`, `async run(ctx: OrderContext, sink: ProgressSink) -> StageResult`), the `ProgressSink` Protocol (`async start_step(step) -> int`, `async finish_step(step, event_id, info)`, `async publish(event_id, step, progress, info)`), and an `OrderContext` dataclass (order_id, prompt, language, target_count, category, theme, facts: list, questions: list, scores: dict, cost_cents: int). **Interfaces only** — no implementations, no imports of FactSourcer/etc yet.
      **Acceptance**: `python -c "from app.orchestrator import Stage, ProgressSink, OrderContext, PackGenerator"` succeeds; `mypy apps/quiz-pack-api/app/orchestrator/` clean; no behaviour change in `process_order` (still stubbed).

- [x] **2.2 `DBProgressSink` implementation.** Implement `DBProgressSink(session_factory, redis, channel)` in `progress_sink.py`. Move the `append_step` + `redis.publish` calls currently inlined in `app/worker/tasks.py:process_order` into this class. The stub `process_order` should be refactored to use `DBProgressSink` (still doing its stub walk) — proves the seam is correct without changing observable behaviour.
      **Acceptance**: `pytest tests/integration/test_order_e2e.py` still passes (same ~7 events on SSE, `total_cost_cents == 0`); no new files outside `app/orchestrator/`; `git grep -n "append_step" apps/quiz-pack-api/app/worker/tasks.py` returns 0 hits.

- [x] **2.3 `PackGenerator` class composing stages.** Implement `PackGenerator(stages: list[Stage], sink_factory: Callable[[str], ProgressSink])` in `pack_generator.py`. `run(order: GenerationOrder) -> QuestionPack` walks each stage in order, accumulates `ctx.cost_cents`, catches stage exceptions, and on failure marks job `failed` with `error=repr(exc)` (matches the Phase 1 stub failure shape). Reads order + job rows the same way Phase 1's stub does. **No real LLM calls yet** — initial stage list is empty so the orchestrator's only job in this task is exercising the loop.
      **Acceptance**: New unit test `tests/orchestrator/test_pack_generator.py` constructs a `PackGenerator` with three fake `Stage` doubles, asserts they run in order, asserts `cost_cents` accumulates, asserts a raised exception in stage 2 marks the job failed and skips stage 3. `pytest tests/orchestrator -v` green.

### Phase 2B — Stage wrappers

> Each wrapper is a thin adapter: it does **not** rewrite the underlying logic — it constructs the existing collaborator from the order context, calls its existing public method, and merges the result into `ctx`. No prompt changes, no behaviour changes, no extra LLM calls.

- [x] **2.4 `SourcingStage` wrapping `FactSourcer`.** New file `app/orchestrator/stages/sourcing.py`. Constructor takes a `FactSourcer` instance; `run(ctx, sink)` calls `await fact_sourcer.gather_facts(category=ctx.category, theme=ctx.theme, language=ctx.language, n=ctx.target_count * 2)` (heuristic 2× the target so dedup has room to drop), stores results in `ctx.facts`, increments `ctx.cost_cents` with the Tavily-API call count × hard-coded `TAVILY_CENTS_PER_CALL` constant.
      **Acceptance**: `tests/orchestrator/stages/test_sourcing.py` uses a `FactSourcer` double that returns 20 fake `Fact` objects; asserts `ctx.facts` has 20 entries after `run`, asserts the sink saw `start_step("sourcing")` + `finish_step("sourcing", ...)`.

- [ ] **2.5 `GenerationStage` wrapping `AdvancedQuestionGenerator`.** New file `app/orchestrator/stages/generation.py`. Constructor takes an `AdvancedQuestionGenerator` instance. `run(ctx, sink)` calls the existing best-of-N + critique entrypoint with `ctx.facts`, `ctx.target_count`, `ctx.language`. Critique stays inside `AdvancedQuestionGenerator` — best-of-N and the LLM judge are coupled by design (#32 §1.2 keep-list). Generated `Question` instances land in `ctx.questions` with `prompt_seed`, `generation_metadata` (typed `GenerationProvenance`), `source_url`/`source_excerpt` carried over from the `Fact` references.
      **Acceptance**: `tests/orchestrator/stages/test_generation.py` uses a generator double that returns N stub `Question` objects; asserts each has `prompt_seed`, `generation_metadata.pipeline=="fact_first"`, `language==ctx.language`.

- [ ] **2.6 `VerificationStage` wrapping `FactVerifier`.** New file `app/orchestrator/stages/verification.py`. Constructor takes a `FactVerifier` instance; `run(ctx, sink)` calls `await fact_verifier.verify_batch(ctx.questions)` and merges per-question verdicts (`verified`, `verification_score`, `verification_notes`) into each `Question.generation_metadata.extra`. Failed questions (score below threshold) are dropped from `ctx.questions` and the count is reported via `sink.publish(... info={"dropped": n})`.
      **Acceptance**: `tests/orchestrator/stages/test_verification.py` runs a verifier double that flags 2 of 5 questions; asserts `len(ctx.questions) == 3` after stage, asserts the published info includes `dropped: 2`.

- [ ] **2.7 `ScoringStage` wrapping `MultiModelScorer`.** New file `app/orchestrator/stages/scoring.py`. Constructor takes a `MultiModelScorer` instance; `run(ctx, sink)` calls `await scorer.score_batch(ctx.questions)` and writes per-model scores to a new `ctx.scores: dict[str, dict[str, float]]` keyed by `question.id`. Does NOT drop questions — drop policy is a Phase 3 concern.
      **Acceptance**: `tests/orchestrator/stages/test_scoring.py` runs a scorer double; asserts `ctx.scores` keys match `ctx.questions[*].id`.

- [ ] **2.8 `DedupStage` (pgvector cosine + Jaccard).** New file `app/orchestrator/stages/dedup.py`. Constructor takes a `PgvectorQuestionStore` (created in 2.16) and the path to `gold_standard.json`. `run(ctx, sink)` for each question:
    - cosine ≥ 0.85 against existing `questions.embedding` where `pack_id IS NULL` OR `pack_id = ctx.pack_id` → drop;
    - Jaccard ≥ 0.80 against `gold_standard.json` titles → drop.
    Dropped count published via `sink.publish(... info={"dropped": n})`.
    > Pgvector store dependency: this task assumes 2.16 is done. If 2.16 is not yet merged, write the stage against the existing `ChromaDBClient` and add a TODO referencing 2.16 — Ralph should pick the order shown here.
      **Acceptance**: `tests/orchestrator/stages/test_dedup.py` seeds 3 near-duplicate questions in the store; asserts the stage drops the 2 cosine-similar ones.

- [ ] **2.9 `PersistStage` (writes pack + questions to Postgres + pgvector).** New file `app/orchestrator/stages/persist.py`. `run(ctx, sink)` inserts a `QuestionPack` row (sets `actual_count = len(ctx.questions)`, `generated_at = now()`, `prompt_embedding` from the embedded prompt for D5/C3-future use), then inserts each `Question` (via `question_to_row`) with `pack_id=pack.id`. Embeddings come from the question's existing `embedding` field; `embedding_model="text-embedding-3-small"`, `embedding_dim=1536`. Final flush returns the pack.
      **Acceptance**: `tests/orchestrator/stages/test_persist.py` runs against the test Postgres; asserts the pack row + N question rows exist with the right `pack_id` + non-null `embedding`; second run with same ids is a no-op (uses `ON CONFLICT DO NOTHING` on `questions.id`).

### Phase 2C — Wire it up

- [ ] **2.10 Swap `process_order` stub for `PackGenerator.run()`.** Edit `apps/quiz-pack-api/app/worker/tasks.py` so `process_order` constructs a `PackGenerator` with the six real stages (2.4–2.9) and runs it. Worker startup (in `app/worker/worker.py`) builds LLM clients once and passes them into the stage constructors via the ARQ `ctx`. Remove the stub `_persist_pack` + `_STEPS`/`_PROGRESS` walk.
      **Acceptance**: `pytest tests/integration/test_order_e2e.py` still passes against mocked HTTP LLM responses (task 2.11 sets these up). Worker boots without import errors; `arq app.worker.WorkerSettings --check` exits 0.

- [ ] **2.11 Real-pipeline e2e test.** Update `tests/integration/test_order_e2e.py`:
    - Mock OpenAI / Anthropic / Tavily / Gemini at the HTTP boundary using `respx` (or `pytest-httpx` — pick whichever is already in `pyproject.toml`; if neither, add `respx` to the test extras).
    - Each mock returns a small canned response (one fact per source, one question per generation request, scores 7.5/8.5, verifier verdict `verified=true`).
    - Bump the cost guardrail: `total_cost_cents > 0` AND `total_cost_cents < 100` (Phase 2 sanity ceiling; Phase 3 will tighten with real per-tier caps).
    - Assert every persisted `Question` has a non-null `source_url` (this is the F8 enforcement gate for Phase 2 — see 2.15).
      **Acceptance**: `pytest tests/integration/test_order_e2e.py -v` green locally + in CI. The previous `total_cost_cents == 0` assertion is replaced exactly once; no parallel test branches.

### Phase 2D — Delete the duplicates

- [ ] **2.12 Delete basic `QuestionGenerator` (U1).** Remove `apps/quiz-pack-api/app/generation/generator.py`. Search the repo (`git grep -n "from app.generation.generator\|from \.generator import"`) for callers and switch them to `AdvancedQuestionGenerator`. Update `app/generation/__init__.py` exports.
      **Acceptance**: `python -c "import app.generation"` works; `git grep -n "QuestionGenerator" apps/quiz-pack-api/` only matches `AdvancedQuestionGenerator`; `pytest apps/quiz-pack-api/tests/` green.

- [ ] **2.13 Delete `/api/v1/export/chatgpt` + `build_for_chatgpt` (U2).** Remove the route + helper. Update `app/api/v1/__init__.py` or whichever module registers the router. Search `git grep -n "build_for_chatgpt\|export/chatgpt"` for stragglers.
      **Acceptance**: `curl http://localhost:8003/api/v1/export/chatgpt` returns 404; no test references that endpoint; `git grep -n "build_for_chatgpt"` returns 0 hits.

- [ ] **2.14 Delete unused sources + legacy scripts.** Remove:
    - `app/sourcing/czech_slovak_source.py` (U5; functionality already in `WikipediaSource(languages=["sk","cs"])`)
    - `app/sourcing/news_source.py` (U4; RSS too brittle, deferred indefinitely)
    - `scripts/generate_questions_claude.py` (replaced by `scripts/generate_pack.py` in 2.16)
    - `scripts/generation_worker.py` (replaced by the real ARQ worker since #33 task 1.10)
    Update `app/sourcing/__init__.py` exports.
      **Acceptance**: `git grep -nE "czech_slovak_source|news_source|generate_questions_claude|generation_worker"` returns 0 hits in code (matches in `docs/issues/issue-32-*.md` are fine and expected); `pytest apps/quiz-pack-api/tests/` green.

### Phase 2E — F8 source quality + thin-client CLI

- [ ] **2.15 Enforce `SourcingStage` is mandatory.** Make `PackGenerator.__init__` raise `ValueError` if no `SourcingStage` is present in the stage list, or if a `SourcingStage` is not the first stage. This guarantees no path through the orchestrator skips real source attribution.
      **Acceptance**: New unit test in `tests/orchestrator/test_pack_generator.py::test_requires_sourcing_first` asserts the `ValueError`. The e2e test from 2.11 already asserts non-null `source_url` end-to-end.

- [ ] **2.16 `scripts/generate_pack.py` CLI thin client.** New file `apps/quiz-pack-api/scripts/generate_pack.py`. Args: `--prompt`, `--language` (default `en`), `--target-count` (default 10), `--category`, `--theme`. Builds an in-memory `GenerationOrder` (no DB insert), constructs a `PackGenerator` with the standard 6 stages and real LLM clients (from env vars), runs it, prints `pack_id` + question summary. Per memory `feedback_qgen_import_cwd`: must run from `apps/quiz-pack-api/` cwd.
      **Acceptance**: `cd apps/quiz-pack-api && python scripts/generate_pack.py --prompt "famous capitals" --target-count 3 --dry-run` prints 3 stub questions (uses the same HTTP mocks as 2.11 when `--dry-run`); without `--dry-run` it'd hit real APIs (not exercised in CI).

- [ ] **2.17 Rewrite `/generate-questions` skill as a thin client.** Edit `.claude/skills/generate-questions/skill.md` so the skill description + body delegates to `scripts/generate_pack.py` instead of orchestrating the pipeline inline. The skill's role becomes: gather params from the user, shell out to the script, summarize results. Strip any prompt/critique logic the skill currently duplicates.
      **Acceptance**: `.claude/skills/generate-questions/skill.md` no longer mentions best-of-N, critique, or fact-sourcing as skill-side logic. A grep for prompt-engineering snippets returns 0 hits inside the skill file. (The skill is loaded lazily by Claude Code, so no test runner — manual smoke check via `git diff` is the acceptance.)

### Phase 2F — M-2 retry endpoint

- [ ] **2.18 `POST /v1/orders/{id}/retry` endpoint.** Add to `app/api/v1/orders.py`. Authz: `X-StoreKit-JWS` matching the original `transaction_id` (reuse the JWS verify cache from #33 task 1.11). Body: empty. Flow:
    - Load order. If `status != "failed"` → 409 Conflict.
    - If `retry_count >= 3` → 422 Unprocessable.
    - Else: reset job to `status="queued"`, increment `retry_count`, clear `error`, set order `status="pending"`, re-enqueue ARQ task. Return 202 with the same `order_id`.
      **Acceptance**: `tests/integration/test_order_retry.py` (new) exercises the four branches: success, conflict on non-failed, 422 on retry cap, 401 on bad JWS.

### Phase 2G — Voice-quiz pgvector cutover (#32 §2.4.1)

- [ ] **2.19 `PgvectorQuestionStore` in shared package.** New file `packages/shared/quiz_shared/database/pgvector_client.py`. Implements the `QuestionStore` protocol used by `QuestionRetriever`: `get(id)`, `count(filters)`, `query(query_text, n_candidates, filters)` (cosine similarity via pgvector `<=>` operator), `add(question)` (writes embedding + metadata to `questions` table). Async-only — uses the existing `app.db.engine` via a passed-in `AsyncSession` factory, or constructs its own from `DATABASE_URL`.
    > Tradeoff: `QuestionRetriever` is currently sync (uses `ChromaDBClient` which is sync). This task adds an async client; 2.20 wires it via `asyncio.run` at the retriever seam, accepting the minor blocking cost in the voice-quiz hot path. Full async migration of the voice quiz is out of scope.
      **Acceptance**: `tests/test_pgvector_client.py` round-trips one question, asserts cosine query returns it as the top match. Lives in `packages/shared/tests/` if that exists, else `apps/quiz-pack-api/tests/`.

- [ ] **2.20 Switch `QuestionRetriever` default store to pgvector.** Edit `apps/quiz-agent/app/retrieval/question_retriever.py` line 32 from `ChromaDBClient().store` → `PgvectorQuestionStore(...)`. Wire `DATABASE_URL` via the quiz-agent settings (add to `app/config.py` if not there). Run `pytest apps/quiz-agent/tests/` and verify voice-quiz behaviour parity on a sample query (top-5 question ids should overlap ≥ 4/5 with ChromaDB results — this is a smoke check, not a strict assertion, because ivfflat is approximate).
      **Acceptance**: `pytest apps/quiz-agent/tests/` green. Manual smoke: `cd apps/quiz-agent && uvicorn app.main:app --port 8002` boots, `curl localhost:8002/health` returns 200, `curl localhost:8002/api/v1/questions/next` returns a question with non-null `source_url`.

- [ ] **2.21 Lock ChromaDB read-only + update memory + backend rules.** Edit `.claude/rules/backend.md` so the "Database" section reflects pgvector as the voice-quiz read path; ChromaDB is documented as read-only until Phase 6 retirement. Update memory note `project_quiz_pack_prod_state.md` (or add a new one if more appropriate) to capture the cutover date + the Phase 6 retirement plan. The ChromaDB volume on Fly stays mounted but no code writes to it.
      **Acceptance**: `git grep -n "ChromaDB" .claude/rules/backend.md` mentions read-only status. Memory file updated and indexed in `~/.claude/projects/.../memory/MEMORY.md`. No code change in this task.

### Phase 2H — Wrap-up

- [ ] **2.22 Close out: TODO, INDEX, #32 cross-references.** Flip `[ ] #36` → `[x] #36` in `docs/todo/TODO.md`. Flip the `[~]` Ralph WIP line to reference the *next* handoff file (after Ralph run completes — operator updates this manually). Add a row in `docs/issues/INDEX.md`. Edit `docs/issues/issue-32-on-demand-generation-service.md` §3 Phase 2: append `**Status:** decomposed into #36; ships YYYY-MM-DD.` and update §5 "Resume" issue-number forecasts (Phase 3 → #37, etc — matches header note above).
      **Acceptance**: `git grep -n "#36" docs/` shows the new issue is referenced from TODO, INDEX, and #32. `git log --oneline -1` is the close-out commit.

---

## Sequencing

Strict order: **2.1 → 2.2 → 2.3 → (2.4..2.9 in any order; 2.8 prefers 2.19 first) → 2.10 → 2.11 → (2.12..2.14 any order) → 2.15 → 2.16 → 2.17 → 2.18 → 2.19 → 2.20 → 2.21 → 2.22**.

Ralph should pick the first unchecked `- [ ]` top-to-bottom. The only out-of-order hint is 2.8 ↔ 2.19: if 2.8 is reached before 2.19, write the dedup stage against `ChromaDBClient` and leave a `# TODO(2.19): swap to PgvectorQuestionStore` comment — do not block.

---

## Risk register

| # | Risk | Mitigation |
|---|---|---|
| R10 | Real LLM calls leak into CI through 2.11's HTTP mocks | `respx` (or chosen lib) configured with `assert_all_called=False, assert_all_mocked=True`; any unmocked HTTPS request raises in the test. Smoke-check by running `pytest tests/integration/test_order_e2e.py` with the network blocked (`HTTPS_PROXY=http://0.0.0.0:1`). |
| R11 | `AdvancedQuestionGenerator` constructor signature changes between Phase 1 and 2.5 wrap | Pin the constructor's current keyword args in `tests/orchestrator/stages/test_generation.py` with a fixture; if the constructor signature shifts in a future PR, the test breaks loudly. |
| R12 | pgvector ivfflat recall worse than ChromaDB for voice-quiz queries (#33 R1) | 2.20 includes a top-5 overlap smoke check. If overlap < 4/5 on a sampled 20-query suite, raise `lists` to 200 or open a Phase 6 follow-up to switch to HNSW (pgvector ≥ 0.5). Do not block 2.20 — voice-quiz UX has fallback through `n_candidates=50` semantic over-fetching. |
| R13 | `SourcingStage` mandatory check (2.15) breaks an admin path that currently skips sourcing | The `/generate-questions` skill is the only such path historically; 2.17 rewrites it to go through `PackGenerator`. Run `pytest apps/quiz-pack-api/tests/` after 2.15 to catch any other regression. |
| R14 | M-2 retry endpoint (2.18) races with an in-flight ARQ job → double-enqueue | Loading the order in 2.18 must be `SELECT ... FOR UPDATE` (Postgres row lock); ARQ's own job dedup is best-effort, not transactional. Test in 2.18's acceptance suite. |
| R15 | Voice-quiz pgvector cutover (2.20) breaks production before Phase 1's ChromaDB → Postgres migration (#33 task 1.7) is fully synced | #33 1.7 reported `done 2026-05-16 (prod migrated, 358 rows)`. Verify count before merging 2.20: `psql $PROD_DATABASE_URL -c "SELECT count(*) FROM questions WHERE pack_id IS NULL AND review_status='approved'"` must equal the ChromaDB count read from `quiz-agent-api`. If they differ, re-run #33 task 1.7 before proceeding. |

---

## Definition of done

1. `PackGenerator` orchestrator lives in `app/orchestrator/`, composed of 6 stages, with `DBProgressSink` writing to Postgres `step_log` + Redis pubsub on every transition.
2. `process_order` (worker) is a thin `await PackGenerator.run(order)` — no inline pipeline code.
3. E2E test (`test_order_e2e.py`) runs the full pipeline against mocked LLM HTTP calls; asserts non-zero `total_cost_cents`, non-null `source_url` on every persisted question, and SSE resume from `Last-Event-ID`.
4. `apps/quiz-pack-api/app/generation/generator.py`, `app/sourcing/{czech_slovak_source,news_source}.py`, `/api/v1/export/chatgpt`, `scripts/generate_questions_claude.py`, `scripts/generation_worker.py` no longer exist.
5. `/generate-questions` skill delegates to `scripts/generate_pack.py` — zero pipeline logic inside the skill.
6. `POST /v1/orders/{id}/retry` ships with the four-branch test suite.
7. Voice quiz (`apps/quiz-agent`) reads questions from Postgres+pgvector via `PgvectorQuestionStore`; ChromaDB is documented as read-only.
8. `apps/quiz-agent/tests/` + `apps/quiz-pack-api/tests/` + `tests/integration/test_order_e2e.py` all green.
9. TODO `[x] #36`; INDEX.md row added; #32 §3 Phase 2 marked as decomposed + shipped.
10. Memory updated: `project_quiz_pack_prod_state` (or successor) reflects pgvector-as-canonical for voice quiz.

---

## Out-of-scope traceability (target phase issue numbers)

- **#37 Phase 3** — OpenAI Moderation, fact-pool cache (D5/C3), per-tier cost cap, prompt caching, stuck-job reconciler. Picks up H-1 (cost-cap mid-flight), H-2 (multilingual moderation), M-3 (embedding model versioning vs cache).
- **#38 Phase 4a** — iOS non-consumable purchase flow, SSE progress UI, language confirmation modal, `Transaction.beginRefundRequest`. Picks up D3 cross-lingual reuse (the iOS language modal forces the design).
- **#39 Phase 4b** — Subscription + ASSN V2 + entitlement state machine. Picks up H-4 (refund detection gap), M-4 (`user_id` migration).
- **#40 Phase 5** — Langfuse, DeepEval, Sentry on quiz-pack-api. Picks up D2 moderation drift observability.
- **#41 Phase 6** — Decommission ChromaDB volume; remove ChromaDB client from `quiz-agent`; retire `project_prod_chroma_mount` memory note.

---

## Pointers

- `Question` Pydantic + `GenerationProvenance` — `packages/shared/quiz_shared/models/question.py`
- Phase 1 worker stub (the file 2.10 replaces) — `apps/quiz-pack-api/app/worker/tasks.py:process_order`
- Phase 1 SSE stream + JWS verify cache (reused by 2.18) — `apps/quiz-pack-api/app/api/v1/orders.py` + `app/sse/`
- Existing pipeline collaborators (the things 2.4–2.7 wrap, untouched) — `apps/quiz-pack-api/app/{sourcing,generation,verification,scoring}/`
- Existing voice-quiz retriever (the file 2.20 edits) — `apps/quiz-agent/app/retrieval/question_retriever.py`
- ChromaDB → Postgres migration script (verify before 2.20) — `apps/quiz-pack-api/scripts/migrate_chroma_to_postgres.py`
- Ralph driver — `scripts/ralph/ralph.sh`; smoke focus file as a shape reference — `scripts/ralph/test/smoke-focus.md`
- Constraining memory notes: `feedback_qgen_import_cwd`, `feedback_secrets_management`, `feedback_no_gitflow`, `feedback_commit_autonomy`, `feedback_file_size_limit`, `project_dockerfile_drift`, `project_prod_chroma_mount`
