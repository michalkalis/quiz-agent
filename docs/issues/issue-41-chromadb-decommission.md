# Issue #41 — ChromaDB decommission (Phase 6 of umbrella #32)

**Triage:** chore/infra · needs-triage
**Status:** in-prep (/prepare-issue)
**Created:** 2026-07-06
**Reversibility:** Phase A = class a (reversible, loop-eligible); Phase B = class c (founder-gated, human-run) — split call made in Phasing below.

## Why

Founder decision 2026-07-06: remove ChromaDB entirely — stop maintaining two databases; pgvector (Postgres) is the sole question store. pgvector is a strict superset of the ChromaDB corpus (565 vs 410 rows, verified 2026-06-25 during #60 prep). ChromaDB has been contractually read-only since the #36 pgvector cutover (2026-05-28). Its transitive deps (~100MB: onnxruntime, grpc, otel) forced the quiz-pack-api VM from 256mb → 512mb after the 2026-07-05 OOM incident; removal enables downsizing back.

Raw scope input (founder prompt + 2026-07-06 recon): live surfaces to migrate/retire —
1. quiz-agent FeedbackService rating write-path (`app/rating/feedback.py`) + eager `ChromaDBClient` import (`app/main.py:59`) + read-fallback when `DATABASE_URL` unset (`main.py:192-194`)
2. `QuestionMonitor` health check (`app/monitoring/question_monitor.py`)
3. quiz-pack-api legacy `POST /questions/approve` → `storage.approve_question` (lazy chroma property in `app/generation/storage.py`)
4. Dedup: `PgvectorQuestionStore` lacks `find_duplicates`; #70 notes dedup queries the frozen empty ChromaDB — port to pgvector
5. Startup check `verify_chroma_path_on_volume` + `CHROMA_PATH` secret + Fly volume `quiz_agent_data` + `/data/chroma` mkdir in Dockerfile
6. `chromadb>=0.4.0` dep in `packages/shared/pyproject.toml` (sole declaration; both apps pull transitively)
7. One-off `scripts/*` chroma utilities → archive; local `chroma_data/` dir
8. Per issue-32 §Phase 6: decommission Fly volume, remove client, retire startup check + memory note `project_prod_chroma_mount`, JSON artifact cleanup
9. Safety net: final backup/export of ChromaDB before decommission (verify whether git history + `chroma_data_backup.json` suffice)

## Research (Phase 1)

*2026-07-06. Web pass skipped — no open external unknown; pgvector already adopted (#36), build-vs-adopt moot.*

### S1 — FeedbackService + question_store + read-fallback (quiz-agent)

- **FeedbackService** (`apps/quiz-agent/app/rating/feedback.py`) does **not** keep a separate rating collection. `submit_rating` (feedback.py:77-83) mutates the question's own metadata in Chroma collection `quiz_questions` — `user_ratings` (JSON dict `{user_id: int}`) + `usage_count` — via `store.upsert`; the detailed record already goes to **SQLite** `data/ratings.db` (`QuestionRating`, feedback.py:85-98, main.py:203-207). `flag_question` (feedback.py:146-170) sets `review_status/review_notes` via `store.upsert`.
- **Readers:** Chroma-side `user_ratings` is only read back on Question deserialize (`question_store.py:326,385` → `average_rating` property); no endpoint/generation consumes it. SQL-side getters (`get_average_rating`, `get_low_rated_questions`, etc.) have **zero callers** — dead read path.
- ⇒ **No new table / Alembic migration needed**: ratings already persist in `ratings.db`; the Chroma write can simply be dropped (or, if aggregate rating on the question row is wanted later, add nullable cols to `quiz_pack.questions` — defer). Endpoints: `POST /sessions/{id}/rate` and `/flag` (quiz.py:262-338).
- **question_store admin surface** (main.py:178, always Chroma): 5 admin-key-gated endpoints in `admin.py` — import (get/find_duplicates/add, :134-198), backfill-sources (get/upsert, :222-262), list (get_all, :276), stats (get_all, :309), delete (get/delete, :343). Kept on Chroma because async `PgvectorQuestionStore` lacks the write surface (see S3).
- **Read-fallback** (main.py:179-196): applies to `retrieval_store` (voice read path) — pgvector via `SyncPgvectorStore` when `DATABASE_URL` set, else Chroma with a warning. **Local-dev story after removal:** require `DATABASE_URL` pointing at the colima dev-stack Postgres (#73) — fail loud at startup instead of a silent Chroma fallback.

### S2 — QuestionMonitor

`app/monitoring/question_monitor.py`: `GET /api/v1/admin/health` (main.py:439-446) → `check_health()` does `collection.get(include=["metadatas"])` (:94) and derives counts by `review_status/difficulty/topic`, expiry, usage, runway (thresholds :53-55). No pgvector equivalent exists; it's plain aggregation — port to one SQL GROUP BY over `quiz_pack.questions` (async session already available). `should_trigger_generation` (:173) has no caller — delete.

### S3 — PgvectorQuestionStore API gap

Protocol (`packages/shared/quiz_shared/database/question_store.py:28-53`): add/upsert/get/delete/search/count/get_all/find_duplicates. `PgvectorQuestionStore` (`pgvector_client.py:117`, async) has add/get/count/search/**find_duplicates** (:215, ported — #70 fear is stale). **Missing: `upsert`, `delete`, `get_all`** — exactly the admin+feedback write surface. Dedup in quiz-pack-api already runs on pgvector (`worker.py:79-81` injects `SyncPgvectorStore(PgvectorQuestionStore(...))`; `dedup.py:93`); only stale ChromaDB comments remain in `dedup.py:5-24,89-91`.

### S4 — quiz-pack-api legacy approve flow

`POST /api/v1/questions/approve` (routes.py:183) and the approve branch of `POST /reviews/submit` (routes.py:399) are the **only remaining ChromaDB writers** repo-wide — via lazy `storage.chroma` property (`app/generation/storage.py:54-64`; writes at :133 etc.). Generation PAUSED since 2026-06-12; ChromaDB contractually read-only since 2026-05-28 (`.claude/rules/backend.md`). ⇒ **Retire** endpoints + `approve_question`/`bulk_approve` Chroma path rather than port; future approval flow is #42 Track F / #30 scope. Removing the lazy property also unblocks dropping the chromadb dep.

### S5 — Dependency

`chromadb>=0.4.0` declared **only** in `packages/shared/pyproject.toml:8`; neither app declares it. Removing it (plus `chroma_client.py`, `ChromaDBQuestionStore`) drops ~100MB transitives (onnxruntime/grpc/otel) from both apps → quiz-pack-api can retry 256MB (memory: upstash/OOM note; chromadb import-bloat fix listed open there — this closes it). Also update both hand-maintained Dockerfile pip lists (memory: `project_dockerfile_drift`).

### S6 — Fly infra: volume is SHARED — do not delete

`fly.toml:36-38` mounts volume `quiz_agent_data` at `/data`. **`/data` holds more than chroma:** `/data/chroma` (Dockerfile:65), `/data/ratings.db` (main.py:203-205, also backs session persistence via same engine, `session/manager.py:23`), `/data/translations.db` (`translation/translator.py:66`), `/data/tts_cache/` (`tts/cache.py:40`). ⇒ **Scope decommission to deleting `/data/chroma` contents only; the volume and mount stay.** Also remove: `CHROMA_PATH` secret (= `/data/chroma`, `docs/runbooks/fly-deploy.md:33`), `verify_chroma_path_on_volume` (`startup_checks.py:24-65` — chroma-specific device-id check; volume itself still needed for the sqlite/tts data), Dockerfile mkdir, eager import `main.py:59`, memory note `project_prod_chroma_mount`.

### S7 — Scripts & local artifacts

Chroma-touching one-offs to archive (never delete ad hoc): repo `scripts/`: backfill_chroma_metadata, update_example_library, diff_prod_vs_local, approve_quiz_agent_questions, check_db_status, migrate_chromadb_to_cosine, remove_invalid_questions, evaluate_rag_quality, migrate_language_dependent, check_quiz_agent_db, apply_question_corrections, import_rated_questions, populate_db, expire_questions, test_cached_embeddings, test_optimization, update_corrected_questions, backfill_sources. Plus `apps/quiz-agent/scripts/backup_questions.py`, `apps/quiz-agent/{export,import}_questions.py`, `populate_local_db.py`, `test_chromadb.py`, `apps/quiz-pack-api/scripts/migrate_chroma_to_postgres.py`, `data/issue63/*.py`. Local `chroma_data/` dir at repo root. Tests referencing chroma: `test_question_storage_pending.py`, `test_question_provenance.py`, `tests/db/test_pgvector_dedup.py`, `tests/orchestrator/stages/test_dedup.py`.

### S8 — Backup / superset verification

pgvector ⊇ chroma verified: `docs/handoffs/handoff-2026-06-25-2017.md:27` — "pgvector `quiz_pack.public.questions` = 565 rows … vs ChromaDB baseline (`quiz_questions`) = 410 approved embeddings → pgvector is a strict superset, same language profile." Existing `chroma_data/chroma_data_backup.json` is a **partial old export** (89 ids, ~81KB, `q_imported_*`) — not sufficient alone. Safety net before wipe: run `apps/quiz-agent/scripts/backup_questions.py` against prod `/data/chroma` (dumps full collection sans embeddings to JSON), commit/stash artifact, then wipe. Embeddings need no backup — pgvector holds all 565 with `vector(1536)`.

### Prior art

- **#36** (`issue-36-quiz-pack-api-phase-2.md:24,32,39`): read-path cutover = swap store behind `DATABASE_URL`, Chroma read-only fallback; volume decommission explicitly deferred to Phase 6 = this issue.
- **#60**: Alembic live in quiz-agent (`apps/quiz-agent/alembic/`, versions 0001-0004; `version_table="alembic_version_quiz_agent"` — shares quiz-pack-db with quiz-pack-api's separate history). Migrations run manually via `fly ssh console` / `fly proxy`; no release_command. Not needed for this issue (no schema change) unless rating cols are added later.

## Scope

**In:** Retire every live ChromaDB code path in quiz-agent + quiz-pack-api; port `QuestionMonitor` and the admin question surface to pgvector; drop the `chromadb` dep + both Dockerfile pip lists; make `DATABASE_URL` mandatory (fail-loud, no Chroma fallback); archive chroma scripts; final prod backup → wipe `/data/chroma` contents → retire `CHROMA_PATH` → retry 256MB VM.

**Out:** Future question review/approval flow (that lands in #42 Track F / #30 — see decision D4). Any question generation work (PAUSED since 2026-06-12). Adding aggregate-rating columns to `quiz_pack.questions` (deferred, D1). Deleting the `quiz_agent_data` Fly volume (shared — D6).

## Resolved design decisions

- **D1 — Drop the Chroma rating write, add no table.** Detailed ratings already persist in SQLite `ratings.db`; the Chroma `user_ratings`/`usage_count` metadata is written but has zero downstream reader (S1). Simplest robust move: stop writing it. Same for `flag_question`'s `review_status` write.
- **D2 — Port `QuestionMonitor` to one SQL aggregate.** Health check is plain counting over `quiz_pack.questions` — replace `collection.get(...)` with a single async GROUP BY; delete the caller-less `should_trigger_generation` (S2).
- **D3 — Extend `PgvectorQuestionStore`, move admin endpoints onto it; keep all 5.** Add async `upsert`, `delete`, `get_all` (the only gap — `find_duplicates` already ported, S3). Second-order review of the 5 admin-key-gated tools against a pgvector corpus: **list/stats** (read-only inventory) and **delete** (yank a bad row) stay clearly useful; **backfill-sources** (upsert source URLs onto existing rows) still valid maintenance; **import** (add) stays as the manual ingest path while generation is paused. None are generation-hot-path, all are admin tools → port rather than retire.
- **D4 — Retire quiz-pack-api approve endpoints + lazy `storage.chroma`.** `POST /questions/approve` and the approve branch of `/reviews/submit` are the only repo-wide Chroma *writers* (S4); generation is paused and Chroma is read-only. Retire rather than port — removing the lazy property unblocks the dep drop. **Second-order:** the future #42/#30 review flow must NOT rebuild on this path — it will write to pgvector via the store's new `upsert`/`delete` surface (D3). Noted here so that issue inherits the constraint.
- **D5 — Drop the `chromadb` dep + both Dockerfile pip lists.** Sole declaration in `packages/shared/pyproject.toml`; removing it + `chroma_client.py`/`ChromaDBQuestionStore` sheds ~100MB transitives (S5). Update both hand-maintained Dockerfiles 1:1 (memory `project_dockerfile_drift`) or deploys crash-loop.
- **D6 — Require `DATABASE_URL`, fail loud.** Remove the silent Chroma read-fallback in `main.py`; startup raises if `DATABASE_URL` is unset. **Local dev** = colima dev-stack Postgres (#73). No Chroma path remains anywhere.
- **D7 — Wipe `/data/chroma` contents, KEEP the volume.** Volume `quiz_agent_data` at `/data` also holds `ratings.db` (+ session persistence), `translations.db`, `tts_cache/` (S6). Delete only `/data/chroma`; retire the `CHROMA_PATH` secret + `verify_chroma_path_on_volume` startup check + Dockerfile mkdir + eager import + memory note `project_prod_chroma_mount`.
- **D8 — Retry 256MB VM for quiz-pack-api after the dep drop.** Was forced to 512MB by chromadb import-bloat OOM (2026-07-05); downsize and observe. Closes the import-bloat item in the upstash memory note.
- **D9 — Archive scripts, don't delete.** Move the ~20 chroma one-offs (S7) to `docs/archive/scripts-chroma/` (git history is the net); drop local `chroma_data/`.
- **D10 — Final prod backup before wipe.** `chroma_data_backup.json` is a partial 89-id export (S8) — insufficient. Run `apps/quiz-agent/scripts/backup_questions.py` against prod `/data/chroma`, commit the artifact, then wipe. Embeddings need no backup — pgvector holds all 565.

**Also cleared as side effects:** #70's stale-dedup fear (dedup already runs on pgvector, S3 — only remove stale ChromaDB comments in `dedup.py`); memory note `project_prod_chroma_mount`.

## Phasing & reversibility

- **Phase A — code (Class a, reversible, loop-eligible).** D1–D6 + D9: port monitor + admin store, drop feedback/approve Chroma writes, remove client/store/dep/startup-check/imports, require `DATABASE_URL`, archive scripts, update Dockerfiles. Green CI both apps, then deploy + verify health/admin endpoints in prod. All git-revertible.
- **Phase B — destructive prod tail (Class c, founder-gated, human-run).** D7/D8/D10 in order: `backup_questions.py` export (commit artifact) → `rm -rf /data/chroma` → unset `CHROMA_PATH` secret → downsize VM to 256MB and observe. **Do NOT delete the volume.**
- **Recommendation:** split — Phase A is agent-runnable (loop-eligible), Phase B is a short human-gated checklist. Justification: Phase A is fully reversible and independently verifiable (CI + prod health); gating it behind the founder would idle the reversible bulk on a step that only touches irreplaceable prod data. So the issue lands `ready-for-agent` for Phase A, with Phase B carried as an explicit founder-gated `[HUMAN]` tail.

## Tasks (atomic)

### Phase A — code (Class a, reversible, loop-eligible)

Order keeps the tree green after every task.

- [ ] **A1 — Add `upsert`/`delete`/`get_all` to `PgvectorQuestionStore`** (D3). Async methods in `pgvector_client.py` matching the protocol (`question_store.py:28-53`); expose via `SyncPgvectorStore` wrapper. New write surface, no caller yet — tree stays green.
- [ ] **A2 — Unit-test A1.** `tests/db/test_pgvector_store.py`: upsert insert+update, delete, get_all round-trip against the dev-stack Postgres. Encode WHY (admin write surface must match old Chroma semantics).
- [ ] **A3 — Switch quiz-agent admin endpoints to pgvector** (D3). Point `question_store` (`main.py:178`) + the 5 `admin.py` endpoints (import/backfill-sources/list/stats/delete) at the pgvector store; drop the always-Chroma binding. Tests green.
- [ ] **A4 — Drop Chroma writes in `FeedbackService`** (D1). Remove the `store.upsert` calls in `submit_rating` (feedback.py:77-83) + `flag_question` (feedback.py:146-170); keep the SQLite `ratings.db` record. Also drop the now-unused `question_store=chroma_question_store` arg from the `FeedbackService(...)` construction (`main.py:224`) — no chroma store consumer must remain before A9. Scrub the file's stale ChromaDB comment/docstring refs (`feedback.py:3` module docstring, `:63` doctest example, `:97` inline comment). `/rate` + `/flag` still 200.
- [ ] **A5 — Port `QuestionMonitor` to one SQL aggregate** (D2). Replace `collection.get(...)` in `check_health()` with a single async GROUP BY over `quiz_pack.questions`; delete caller-less `should_trigger_generation`; drop the `chroma_client=chroma_client.client` wiring at the monitor construction (`main.py:339`). `GET /api/v1/admin/health` serves pgvector-derived counts.
- [ ] **A6 — Test A4/A5.** Update the SQL health-monitor test to assert counts from Postgres; adjust feedback tests to assert no Chroma write + SQLite record persists.
- [ ] **A7 — Require `DATABASE_URL`, remove Chroma read-fallback** (D6). `main.py:179-196` raises loud at startup if `DATABASE_URL` unset; `retrieval_store` always pgvector. No silent Chroma path.
- [ ] **A8 — Retire quiz-pack-api approve endpoints + lazy `storage.chroma`** (D4). Remove `POST /questions/approve` (routes.py:183), the approve branch of `/reviews/submit` (routes.py:399), and `approve_question`/`bulk_approve` Chroma path + lazy property (`storage.py:54-64`). Remove stale ChromaDB comments in `dedup.py:5-24,89-91`.
- [ ] **A9 — Remove all remaining quiz-agent Chroma wiring + startup check + `CHROMA_PATH` refs** (D6/D7, code-only). By now (after A3/A4/A5/A7) nothing consumes the chroma client/store, so remove EVERY remaining wiring site in `main.py`: eager import (`:59`), module global `chroma_client` (`:86` + its name in the `global` stmt `:101`), the whole init block `:131-162` (the `ChromaDBClient(...)` construction `:149`, the `verify_chroma_path_on_volume` call `:147`, `CHROMA_PATH` reads `:134-140`, `chroma_question_store = chroma_client.store` `:156`), and `app.state.chroma_client = chroma_client` (`:373`). Also delete the caller-less `get_chroma_client` DI provider (`app/api/deps.py:373-375`) and `verify_chroma_path_on_volume` itself (`startup_checks.py:24-65`), plus the Dockerfile `/data/chroma` mkdir. Keep the volume + mount (holds ratings/translations/tts). **Sweep remaining stale chroma comments/docstrings in touched app source so the acceptance grep is genuinely empty:** the `logging.getLogger("chromadb")` quiet-line (`logging_config.py:62`) and the read-only comment in `retrieval/question_retriever.py:36`. After this task `grep -riE 'chroma' apps/quiz-agent/app --include='*.py'` is empty. Secret unset is Phase B.
- [ ] **A10 — Delete Chroma client/store + drop the dep** (D5). Remove `chroma_client.py`, `ChromaDBQuestionStore`, and `chromadb>=0.4.0` from `packages/shared/pyproject.toml:8`; update BOTH Dockerfile hand-maintained pip lists 1:1 (memory `project_dockerfile_drift`); regenerate `uv.lock`. Scrub the lazy-export scaffolding + stale docstring in `packages/shared/quiz_shared/database/__init__.py:3,5,7,18` (the PEP 562 `__getattr__` chroma branch) so no chroma ref survives the acceptance grep in `packages/shared`. Both suites green.
- [ ] **A11 — Retire/update chroma-referencing tests** (S7). Update or delete `test_question_storage_pending.py`, `test_question_provenance.py`, `tests/db/test_pgvector_dedup.py`, `tests/orchestrator/stages/test_dedup.py` so no test imports chromadb; suites green. **Guard (Gate B):** after A10's dep drop, confirm no surviving test module has a live `import chromadb` (a stale one breaks at collection time, not just runtime) — `grep -rn 'import chromadb' apps/quiz-agent/tests apps/quiz-pack-api/tests` must be empty. Stale comment/docstring chroma mentions in tests (e.g. `test_session_manager.py:17`) are fine — only live imports break collection.
- [ ] **A12 — Archive chroma scripts + drop local `chroma_data/`** (D9). Move the ~20 one-offs (S7) to `docs/archive/scripts-chroma/`; delete repo-root `chroma_data/`. (Keep `backup_questions.py` reachable for Phase B — archive a copy, retain the runnable path.)
- [ ] **A13 — Retire memory note + deploy Phase A.** Remove/annotate `project_prod_chroma_mount`; deploy both apps to Fly; verify `/api/v1/admin/health` + admin endpoints against prod pgvector.

### Phase B — destructive prod tail (Class c, `[HUMAN]` / founder-gated)

Run in order. **Do NOT delete the `quiz_agent_data` volume.**

- [ ] **B1 [HUMAN]** — Final prod backup (D10): run `apps/quiz-agent/scripts/backup_questions.py` against prod `/data/chroma` via `fly ssh console`; **verify the artifact** (row count ≈ 410, non-empty JSON) and commit/stash it.
- [ ] **B2 [HUMAN]** — Wipe: `rm -rf /data/chroma` contents on the Fly volume (mount + volume stay).
- [ ] **B3 [HUMAN]** — Unset `CHROMA_PATH` secret (`fly secrets unset CHROMA_PATH`); redeploy; verify health green.
- [ ] **B4 [HUMAN]** — Downsize quiz-pack-api VM to 256MB (D8); observe for OOM over normal load.

## Acceptance

### Phase A (agent-verifiable)

- [ ] No live Chroma identifier survives — not just the literal `chromadb` but dangling `chroma_client` / `chroma_question_store` / `get_chroma_client` / `state.chroma_client` / `verify_chroma_path`: `grep -riE 'chroma' apps/quiz-agent/app apps/quiz-pack-api/app packages/shared --include='*.py'` returns **empty** (this fails today — the wiring in `main.py`, `deps.py`, `storage.py`, monitor, and the `chroma_client.py` module all match — and passes only after A3–A10). Scope is app source; the Phase-B backup tool `apps/quiz-agent/scripts/backup_questions.py` and `docs/archive/` are intentionally excluded (archived/retained tooling, not a live import path).
- [ ] `grep -rn "chromadb" packages/shared/pyproject.toml uv.lock` — no `chromadb` dependency line; absent from `uv.lock`.
- [ ] Both Dockerfile pip lists contain no `chromadb`: `grep -rn chromadb apps/*/Dockerfile` empty.
- [ ] quiz-agent suite green: `cd apps/quiz-agent && pytest tests/ -v` (no skips of migrated tests).
- [ ] quiz-pack-api suite green: `cd apps/quiz-pack-api && pytest tests/ -v`.
- [ ] New store methods tested: `pytest apps/quiz-agent/tests/db/test_pgvector_store.py -v` covers upsert/delete/get_all.
- [ ] No test module has a live `import chromadb` after the dep drop (would break at pytest collection): `grep -rn "import chromadb" apps/quiz-agent/tests apps/quiz-pack-api/tests` empty.
- [ ] quiz-agent boots with `DATABASE_URL` unset → fails loud with a clear error (no Chroma fallback); inspect startup log / run `uvicorn app.main:app` sans `DATABASE_URL`.
- [ ] Admin endpoints work against pgvector: curl `import`, `backfill-sources`, `list`, `stats`, `delete` (admin-key-gated) return 200 with pgvector-derived data.
- [ ] `GET /api/v1/admin/health` returns pgvector-derived counts (curl; counts match a direct `SELECT count(*) ... GROUP BY review_status` on `quiz_pack.questions`).
- [ ] `POST /rate` and `/flag` return 200 and write only to SQLite `ratings.db` (no Chroma write; inspect code + test).
- [ ] quiz-pack-api `POST /questions/approve` returns 404/410 (retired); `grep -n "storage.chroma\|def approve_question" apps/quiz-pack-api` empty.
- [ ] Chroma one-off scripts live under `docs/archive/scripts-chroma/`; repo-root `chroma_data/` absent (`ls`).
- [ ] Both apps deployed; prod health + admin endpoints verified (curl prod URLs).

### Phase B ([HUMAN], founder-gated — verify after each step)

- [ ] **[HUMAN]** Backup artifact exists and verified non-empty (~410 rows) before any wipe (file inspection).
- [ ] **[HUMAN]** `fly ssh console -C 'ls /data/chroma'` empty; `/data/ratings.db`, `/data/translations.db`, `/data/tts_cache/` intact; volume + mount still present (`fly volumes list` shows `quiz_agent_data`).
- [ ] **[HUMAN]** `fly secrets list` shows no `CHROMA_PATH`; post-redeploy health green.
- [ ] **[HUMAN]** quiz-pack-api VM at 256MB (`fly scale show`) with no OOM over an observation window.

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done | — |
| 2 · Plan              | ✅ done | — |
| 3 · Plan review       | ✅ done | ready-check READY · design-soundness SOUND (0.9) |
| 4 · Impl-plan         | ✅ done | — |
| 5 · Impl-plan review  | 🔁 in progress | attempt 1 FAIL — Gate B: A9/A10 missed live wiring sites (main.py:149 construction, :373 app.state, deps.py get_chroma_client) → red build; vacuous `chromadb`-only acceptance grep. Fixed in re-impl cycle 2. |
| 6 · Split             | ⬜ pending | — |

**Last updated:** 2026-07-06 · **Next:** Phase 5 re-review · **Gate attempts:** P3 1/3 (pass) · P5 1/3 (attempt 1 fail, re-impl done)
