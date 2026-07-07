# Issue #70 — Backend: ARQ worker Docker-path crash + dedup store wiring (content-pipeline residuals)

**Triage:** bug · **done 2026-07-07** — both halves resolved elsewhere; nothing left to do.

**Closed (2026-07-07, verified first-hand during session-split):** the remaining `worker.py` `parents[4]` crash was already fixed by `649b1b9` (#60.P3 — commit cites #70), which replaced the fixed index with `find_in_ancestors` from `quiz_shared.paths` (`app/worker/worker.py:17,31`); the dedup half was superseded by #41 (closed 2026-07-07, dedup lives on pgvector). No code matches the described bug anymore.

**Note (2026-07-06):** the dedup/ChromaDB half is superseded by #41 findings — dedup already runs on pgvector (`find_duplicates` exists and the worker wires it); only stale ChromaDB comments remain in `dedup.py`, owned by #41. Remaining live scope in this issue = only the `worker.py` `parents[4]` Docker-path import crash.

**Created:** 2026-06-21 · **Founder:** Michal · **Source:** #64 full-project review (rank 8, 18 — verified first-hand)

**Severity:** medium — latent (generation is paused), but both would bite the moment generation resumes.

## Context / correction

The #64 review's headline "MCQ yields 0% — implement structured output (task 42.25)" was
**refuted on first-hand read**: `with_structured_output(MCQBatchOutput, method="function_calling")`
is already shipped (`advanced_generator.py:634`, commit `7805002`) and wired
(`_generate_mcq_sub_batches:247 → _generate_mcq_batch_structured:381/588`). Validating the new MCQ
**yield** is owned by **#63 Track A** (dry-run gate). This issue captures only the two **real,
still-open code defects** the reviewer surfaced underneath that stale claim.

## Problem

1. **ARQ worker would crash at import in the Docker image.** `worker.py` computes the repo root as
   `Path(__file__).resolve().parents[4]`, but in the image the module lands at `/app/worker/worker.py`
   whose `.parents` max out at `/` — `parents[4]` raises `IndexError` at module import, so the worker
   process dies on startup the first time generation resumes.
2. **Dedup is inert in prod.** The dedup stage queries the **frozen, empty ChromaDB** (no writes
   since 2026-05-28) and `PgvectorQuestionStore` — the live store — has **no `find_duplicates`**.
   So near-duplicate questions pass straight through.

## Evidence (verified first-hand 2026-06-21)

- `apps/quiz-pack-api/app/worker/worker.py:27-28` — `_REPO_ROOT = Path(__file__).resolve().parents[4]`. Dockerfile copies `apps/quiz-pack-api → /build/app → /app` (`Dockerfile:24,56`, `WORKDIR /app`), so the module is `/app/worker/worker.py`; `parents` = `[/app/worker, /app, /]` → `parents[4]` out of range.
- `apps/quiz-pack-api/app/worker/worker.py:52` — `ctx["question_store"] = ChromaDBClient().store` (ChromaDB is read-only/frozen per `.claude/rules/backend.md`).
- `packages/shared/quiz_shared/database/pgvector_client.py` — grep for `find_duplicates` returns nothing.
- A real `DedupStage` exists (`app/orchestrator/stages/dedup.py:45`); it just has no live store to query.
- (Stale: the review's `generate_pack.py:212 _NoopQuestionStore` citation — symbol not present.)

## Recommendation

1. Fix the worker path: resolve `gold_standard.json` relative to the module's own location (or move
   it inside `apps/quiz-pack-api/data/examples/` so it's copied into the image) instead of
   `parents[4]`. Add a Docker-equivalent import smoke test.
2. Add `find_duplicates(embedding, threshold)` to `PgvectorQuestionStore` (cosine-distance `ORDER BY`,
   the pattern already in `.search()` at `pgvector_client.py:204`), and wire the pgvector store as the
   dedup `question_store` in `worker.py:52` (replace ChromaDB).

## Acceptance

- [ ] `app.worker.worker` imports successfully under a Docker-equivalent path (no `parents[4]` error) — covered by a test
- [ ] `PgvectorQuestionStore.find_duplicates` exists and returns IDs above a cosine-similarity threshold
- [ ] `worker.py` dedup uses the pgvector store, not ChromaDB
- [ ] A batch containing a deliberate verbatim repeat drops ≥1 duplicate in `DedupStage`
- [ ] Yield validation of the (already-shipped) structured MCQ path is tracked under #63, not here
