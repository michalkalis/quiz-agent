# Issue #41 — Execution plan + ready-to-paste session prompts

**Created:** 2026-07-06 — split from the ready plan (P5 PASS: ready-check READY · design-soundness SOUND 0.85; founder decision D11 = live-code acceptance). #41 is large (13 code tasks across quiz-agent + quiz-pack-api + `packages/shared`) → 3 agent sessions for **Phase A** (class a, loop-eligible), plus a founder-gated **Phase B** human checklist. Each session below is self-contained: open a fresh session, paste the fenced block, go.

> Parent plan: [`issue-41-chromadb-decommission.md`](issue-41-chromadb-decommission.md). Umbrella: #32 (Phase 6).

---

## Recon snapshot — what the codebase gives us (from #41 S1–S8, verified 2026-07-06)

**Store layer (`packages/shared`):**

- **Protocol** `quiz_shared/database/question_store.py:28-53` — `add/upsert/get/delete/search/count/get_all/find_duplicates`.
- `PgvectorQuestionStore` (`pgvector_client.py:117`, **async**) has `add/get/count/search/find_duplicates` (:215, already ported — #70's stale-dedup fear is moot). **Missing: `upsert`, `delete`, `get_all`** = exactly the admin+feedback write surface to add (A1).
- `SyncPgvectorStore` wraps the async store for sync callers (used in quiz-pack-api `worker.py:79-81`, `dedup.py:93`).
- Chroma types to delete in A10: `chroma_client.py` (`ChromaDBClient` :35/:38, `ChromaDBQuestionStore`), and the PEP 562 `__getattr__` chroma branch + exports in `__init__.py:12,17-20,25-26`.
- Dep declared **only** at `packages/shared/pyproject.toml:8` (`chromadb>=0.4.0`); both apps pull it transitively (~100MB: onnxruntime/grpc/otel).
- ⚠️ Historical comments/docstrings referencing `ChromaDBQuestionStore` (e.g. `pgvector_client.py:6,219`) MAY STAY (D11) — acceptance greps are import + construction call-form only.

**quiz-agent (`apps/quiz-agent`):**

- `main.py` chroma sites: eager import `:59`; module global `chroma_client` `:86` + `global` stmt `:101`; init block `:131-162` (`CHROMA_PATH` reads `:134-140`, `verify_chroma_path_on_volume` call `:147`, `ChromaDBClient(...)` `:149`, `chroma_question_store = chroma_client.store` `:156`); `question_store` binding `:178` (always Chroma); read-fallback `:179-196`; `FeedbackService(...)` `:224`; monitor wiring `:339` (`chroma_client=chroma_client.client`); `app.state.chroma_client` `:373`. SQLite `ratings.db` engine `:203-207`.
- `admin.py` — 5 admin-key-gated endpoints (import :134-198, backfill-sources :222-262, list :276, stats :309, delete :343), all on `question_store`.
- `rating/feedback.py` — `submit_rating` :77-83 (`store.upsert` of `user_ratings`/`usage_count`), `flag_question` :146-170 (`store.upsert` of `review_status`). Detailed record already → SQLite `ratings.db` :85-98. Chroma `user_ratings` read back only at deserialize (`question_store.py:326,385`); SQL getters have **zero callers**.
- `monitoring/question_monitor.py` — `check_health()` `:94` does `collection.get(include=["metadatas"])`, derives counts by review_status/difficulty/topic + expiry/usage/runway (:53-55). `should_trigger_generation` :173 = **no caller** (delete). Import :11, constructs :63/:75.
- `startup_checks.py:24-65` — `verify_chroma_path_on_volume` (chroma-specific device-id check). `deps.py:373-375` — caller-less `get_chroma_client` DI. `logging_config.py:62` — dead `logging.getLogger("chromadb")` quiet-line. Dockerfile `:65` — `mkdir -p /data/chroma`.
- Endpoints: `/api/v1/admin/health` (main.py:439-446), `POST /sessions/{id}/rate` + `/flag` (quiz.py:262-338).

**quiz-pack-api (`apps/quiz-pack-api`):**

- **Only remaining Chroma writers repo-wide** — `POST /api/v1/questions/approve` (`routes.py:183`) + approve branch of `POST /reviews/submit` (`routes.py:399`), via lazy `storage.chroma` property (`app/generation/storage.py:54-64`, writes :133). Generation PAUSED since 2026-06-12; Chroma read-only since 2026-05-28. → **retire**, don't port (D4).
- `dedup.py` already runs on pgvector; only **stale ChromaDB comments** at `:5-24,89-91` to remove.

**Infra / Fly (S6 — SHARED volume, do NOT delete):**

- `fly.toml:36-38` mounts `quiz_agent_data` at `/data`. `/data` also holds `ratings.db` (+ session persistence, `session/manager.py:23`), `translations.db` (`translation/translator.py:66`), `tts_cache/` (`tts/cache.py:40`). → wipe only `/data/chroma` contents; keep volume + mount.
- `CHROMA_PATH` secret = `/data/chroma` (`docs/runbooks/fly-deploy.md:33`). Both Dockerfiles hand-maintain a pip list (memory `project_dockerfile_drift`) — keep 1:1 with pyproject or deploys crash-loop.

**Tests touching chroma (S7):** `test_question_storage_pending.py`, `test_question_provenance.py`, `tests/db/test_pgvector_dedup.py`, `tests/orchestrator/stages/test_dedup.py`. ⚠️ After the dep drop a live `import chromadb` in any test breaks at **pytest collection**, not runtime — grep-guard it (A11).

**Local dev:** colima dev-stack Postgres (#73) provides `DATABASE_URL` / `TEST_DATABASE_URL`; A1's test hits it.

**Backup (S8):** pgvector ⊇ chroma verified (565 ≥ 410, handoff-2026-06-25-2017). `chroma_data_backup.json` is a partial 89-id export — insufficient; Phase B runs a fresh full export.

---

## Locked decisions (carry into every session — verbatim from #41)

| # | Decision |
|---|---|
| **D1** | Drop the Chroma rating write, add no table — ratings persist in SQLite `ratings.db`; `user_ratings`/`usage_count` + `flag`'s `review_status` have zero readers. Stop writing them. |
| **D2** | Port `QuestionMonitor` to one async SQL GROUP BY over `quiz_pack.questions`; delete caller-less `should_trigger_generation`. |
| **D3** | Extend `PgvectorQuestionStore` (`upsert`/`delete`/`get_all`; `find_duplicates` already ported), move all 5 admin endpoints onto it. All admin tools, none generation-hot-path → port, keep. |
| **D4** | Retire quiz-pack-api approve endpoints + lazy `storage.chroma` (only repo-wide Chroma writers; generation paused). Future #42/#30 review flow must write pgvector via D3's surface — do NOT rebuild on this path. |
| **D5** | Drop the `chromadb` dep + `chroma_client.py`/`ChromaDBQuestionStore`; update BOTH Dockerfile pip lists 1:1; regenerate `uv.lock`. |
| **D6** | Require `DATABASE_URL`, fail loud at startup — remove the silent Chroma read-fallback. Local dev = colima dev-stack Postgres. |
| **D7** | Wipe `/data/chroma` contents only, KEEP the volume (holds ratings/translations/tts). Retire `CHROMA_PATH` + `verify_chroma_path_on_volume` + Dockerfile mkdir + eager import + memory note. |
| **D8** | Retry 256MB VM for quiz-pack-api after the dep drop (was forced to 512MB by import-bloat OOM). |
| **D9** | Archive the ~20 chroma one-offs to `docs/archive/scripts-chroma/` (don't delete); drop local `chroma_data/`. |
| **D10** | Final prod backup before wipe via `scripts/backup_questions.py` (partial JSON insufficient); embeddings need no backup. |
| **D11** | **Acceptance targets LIVE code only** (founder 2026-07-06) — import + construction/attribute-access greps, NOT a blanket `grep -riE 'chroma'`. Historical comments/docstrings may remain. |

---

## Session breakdown

| Session | Tasks | Risk | Notes |
|---|---|---|---|
| **A — pgvector store surface** | A1 + A2 | Low | Add async `upsert`/`delete`/`get_all` to `PgvectorQuestionStore` (+ `SyncPgvectorStore`) + unit tests. New write surface, **no caller yet** → tree stays green. `packages/shared` only. Independently committable. |
| **B — quiz-agent onto pgvector** | A3 + A4 + A5 + A6 + A7 | Med | Depends on **A merged**. Switch admin endpoints + monitor + feedback off Chroma onto the D3 surface; fail-loud `DATABASE_URL`; tests. After B, nothing in quiz-agent *consumes* chroma (wiring removal is C). quiz-agent suite. |
| **C — teardown + dep drop + deploy** | A8 + A9 + A10 + A11 + A12 + A13 | Med | Depends on **B merged**. Retire quiz-pack-api approve; strip remaining quiz-agent wiring + startup check; delete client/store + drop dep + both Dockerfiles + `uv.lock`; retire/guard tests; archive scripts; retire memory note; deploy both apps + verify prod. Both suites + Fly deploy. |
| **Phase B — destructive prod tail** | B1–B4 `[HUMAN]` | — | **NOT a loop session** (class c, founder-gated). Human checklist below; runs only after C is deployed and prod-verified. |

Sessions are strictly sequential (A → B → C); each depends only on already-merged work. Phase A lands `ready-for-agent`; Phase B is the explicit `[HUMAN]` tail.

---

## Ready prompt — Session A (pgvector store surface)

```
Work on issue #41 (ChromaDB decommission), Session A only: tasks A1 + A2 — add the missing write surface to PgvectorQuestionStore + unit tests. Do NOT touch any consumer (admin endpoints, feedback, monitor) — that's Session B. Do NOT delete chroma_client.py or drop the dep — that's Session C. Stop, commit, push when green.

Read first (already mapped — don't re-map):
- docs/issues/issue-41-execution-prompts.md → "Recon snapshot" (Store layer) + "Locked decisions" (D3). Follow exactly.
- packages/shared/quiz_shared/database/question_store.py:28-53 → the protocol (add/upsert/get/delete/search/count/get_all/find_duplicates).
- packages/shared/quiz_shared/database/pgvector_client.py → PgvectorQuestionStore (async, :117; existing add/get/count/search/find_duplicates :215) + SyncPgvectorStore wrapper. Match its idiom for the new methods.
- apps/quiz-pack-api/tests/db/test_pgvector_dedup.py → dev-stack Postgres test pattern (DATABASE_URL / TEST_DATABASE_URL from colima #73).

Build:
1) A1 — Add async `upsert`, `delete`, `get_all` to PgvectorQuestionStore matching the protocol semantics (upsert = insert-or-update by id, matching the old Chroma write semantics; delete by id; get_all returns all rows). Expose each via the SyncPgvectorStore wrapper. New surface, no caller yet — the tree stays green.
2) A2 — apps/quiz-agent/tests/db/test_pgvector_store.py: upsert insert + update round-trip, delete, get_all, against the dev-stack Postgres. Each test must encode WHY (this write surface replaces the old Chroma admin/feedback writes — must match those semantics).

Done = `pytest apps/quiz-agent/tests/db/test_pgvector_store.py -v` green AND both suites still green (`cd apps/quiz-agent && pytest tests/ -v`; `cd apps/quiz-pack-api && pytest tests/ -v`), ruff clean. Commit (store methods; tests), push to main. Tick A1/A2 in docs/issues/issue-41-chromadb-decommission.md.
```

---

## Ready prompt — Session B (quiz-agent onto pgvector)

```
Work on issue #41, Session B only: tasks A3 + A4 + A5 + A6 + A7 — move quiz-agent's live consumers off ChromaDB onto the pgvector store, and make DATABASE_URL mandatory. Session A (upsert/delete/get_all on PgvectorQuestionStore) must be merged first. Do NOT yet delete the chroma client/wiring or drop the dep (Session C) — after B, chroma is simply no longer *consumed*, the objects can still exist. Do NOT touch quiz-pack-api (Session C). Stop, commit, push when green.

Read first (don't re-map):
- docs/issues/issue-41-execution-prompts.md → "Recon snapshot" (quiz-agent) + "Locked decisions" (D1/D2/D3/D6). Follow exactly.
- apps/quiz-agent/app/main.py → question_store binding :178, read-fallback :179-196, FeedbackService(...) :224, monitor wiring :339.
- apps/quiz-agent/app/api/routes/admin.py → the 5 admin-key-gated endpoints (import/backfill-sources/list/stats/delete).
- apps/quiz-agent/app/rating/feedback.py → submit_rating :77-83, flag_question :146-170, SQLite record :85-98.
- apps/quiz-agent/app/monitoring/question_monitor.py → check_health() :94, thresholds :53-55, should_trigger_generation :173 (no caller — delete).
- packages/shared/quiz_shared/database/pgvector_client.py → the Session-A upsert/delete/get_all + SyncPgvectorStore.

Build (order keeps the tree green):
1) A3 — Point question_store (main.py:178) + all 5 admin.py endpoints at the pgvector store (SyncPgvectorStore over PgvectorQuestionStore); drop the always-Chroma binding. Admin endpoints must return pgvector-derived data.
2) A4 — Remove the store.upsert calls in submit_rating + flag_question (keep the SQLite ratings.db record). Drop the now-unused question_store=chroma_question_store arg from the FeedbackService(...) construction (main.py:224). /rate + /flag still 200. Stale chroma comments/docstrings may stay (D11).
3) A5 — Replace collection.get(...) in check_health() with a single async GROUP BY over quiz_pack.questions (async session already available); delete caller-less should_trigger_generation; drop the chroma_client=... wiring at the monitor construction (main.py:339). GET /api/v1/admin/health serves pgvector-derived counts.
4) A6 — Update the health-monitor test to assert counts from Postgres; adjust feedback tests to assert NO chroma write + the SQLite record persists. Tests encode WHY.
5) A7 — main.py:179-196: raise loud at startup if DATABASE_URL is unset; retrieval_store is always pgvector. No silent chroma read path.

Done = `cd apps/quiz-agent && pytest tests/ -v` green (no skips of migrated tests); boot with DATABASE_URL unset fails loud (`uvicorn app.main:app` sans DATABASE_URL); ruff clean. Commit per logical step, push. Tick A3–A7.
```

---

## Ready prompt — Session C (teardown + dep drop + deploy)

```
Work on issue #41, Session C only: tasks A8 + A9 + A10 + A11 + A12 + A13 — retire the last chroma writers, strip all remaining wiring, delete the client + drop the dep, guard/update tests, archive scripts, and deploy Phase A. Sessions A + B merged first (so nothing in quiz-agent consumes chroma). This is the destructive-CODE wave; the destructive PROD steps (wipe /data/chroma, unset secret, downsize VM) are Phase B [HUMAN] — do NOT do them here. Stop, commit, push, deploy when both suites are green.

Read first (don't re-map):
- docs/issues/issue-41-execution-prompts.md → full "Recon snapshot" + "Locked decisions" (D4/D5/D6/D7/D8/D9/D11). Follow exactly.
- apps/quiz-pack-api/app/api/routes.py → approve endpoints :183 + /reviews/submit approve branch :399; apps/quiz-pack-api/app/generation/storage.py → lazy chroma property :54-64, approve_question/bulk_approve; app/orchestrator/stages/dedup.py → stale chroma comments :5-24,89-91.
- apps/quiz-agent/app/main.py → chroma sites :59,:86,:101,:131-162,:373; app/api/deps.py:373-375 (get_chroma_client); app/startup_checks.py:24-65; app/logging_config.py:62; apps/quiz-agent/Dockerfile:65.
- packages/shared/quiz_shared/database/chroma_client.py + __init__.py:12,17-20,25-26; packages/shared/pyproject.toml:8.
- Both Dockerfile pip lists (memory project_dockerfile_drift — keep 1:1 with pyproject or deploys crash-loop).

Build (order keeps the tree green):
1) A8 — Retire POST /questions/approve (routes.py:183) + the approve branch of /reviews/submit (routes.py:399) + approve_question/bulk_approve + the lazy storage.chroma property (storage.py:54-64). Remove stale chroma comments in dedup.py:5-24,89-91. Retired endpoints should 404/410.
2) A9 — Remove EVERY remaining quiz-agent chroma wiring site in main.py (eager import :59; global chroma_client :86 + name in global stmt :101; init block :131-162 incl. ChromaDBClient(...) :149, verify_chroma_path_on_volume call :147, CHROMA_PATH reads :134-140, chroma_question_store :156; app.state.chroma_client :373). Delete caller-less get_chroma_client (deps.py:373-375), verify_chroma_path_on_volume (startup_checks.py:24-65), the Dockerfile /data/chroma mkdir, and the dead logging.getLogger("chromadb") line (logging_config.py:62). KEEP the volume + mount. Secret unset is Phase B.
3) A10 — Delete chroma_client.py + ChromaDBQuestionStore; remove chromadb>=0.4.0 from packages/shared/pyproject.toml:8; update BOTH Dockerfile hand-maintained pip lists 1:1; regenerate uv.lock. Remove the PEP 562 __getattr__ chroma branch + ChromaDBQuestionStore/ChromaDBClient exports in __init__.py:12,17-20,25-26.
4) A11 — Update/delete chroma-referencing tests (test_question_storage_pending.py, test_question_provenance.py, tests/db/test_pgvector_dedup.py, tests/orchestrator/stages/test_dedup.py) so none imports chromadb. GATE: after the dep drop, `grep -rn 'import chromadb' apps/quiz-agent/tests apps/quiz-pack-api/tests` MUST be empty (a live import breaks pytest COLLECTION, not just runtime). Stale comment mentions are fine.
5) A12 — Move the ~20 chroma one-offs (see #41 S7) to docs/archive/scripts-chroma/; delete repo-root chroma_data/. Keep scripts/backup_questions.py reachable for Phase B (archive a copy, retain the runnable path).
6) A13 — Remove/annotate memory note project_prod_chroma_mount; deploy BOTH apps to Fly; verify GET /api/v1/admin/health + the admin endpoints (curl, admin-key-gated) against prod pgvector.

Verify the #41 Phase-A acceptance greps are empty (D11):
- imports: grep -rnE '^\s*(import chromadb|from chromadb|from quiz_shared\.database\.chroma_client|from \.chroma_client)' apps/quiz-agent/app apps/quiz-pack-api/app packages/shared/quiz_shared --include='*.py'
- constructions: grep -rnE 'ChromaDBClient\(|ChromaDBQuestionStore\(|chromadb\.' apps/quiz-agent/app apps/quiz-pack-api/app packages/shared/quiz_shared --include='*.py'
- grep -rn 'chromadb' packages/shared/pyproject.toml uv.lock  → no dep line
- grep -rn chroma apps/quiz-agent/Dockerfile  → empty

Done = both suites green (`cd apps/quiz-agent && pytest tests/ -v`; `cd apps/quiz-pack-api && pytest tests/ -v`, no skips), all acceptance greps empty, ruff clean, both apps deployed + prod health/admin verified. Commit per logical step, push, deploy. Tick A8–A13. This completes Phase A — leave Phase B (B1–B4) for the founder.
```

---

## Human prerequisites — Phase B (destructive prod tail, `[HUMAN]`, founder-gated)

Run ONLY after Session C is deployed and prod-verified. **Do NOT delete the `quiz_agent_data` volume** — it holds `ratings.db`, `translations.db`, `tts_cache/`. Run in order, verify after each step:

1. **B1 — Final prod backup (D10).** `fly ssh console` into quiz-agent; run `apps/quiz-agent/scripts/backup_questions.py` against prod `/data/chroma`. Verify the artifact (row count ≈ 410, non-empty JSON), then commit/stash it. Do not proceed until verified.
2. **B2 — Wipe (D7).** On the Fly volume: `rm -rf /data/chroma` contents (mount + volume stay). Verify `fly ssh console -C 'ls /data/chroma'` is empty and `/data/ratings.db`, `/data/translations.db`, `/data/tts_cache/` are intact.
3. **B3 — Unset secret (D7).** `fly secrets unset CHROMA_PATH`; redeploy; verify health green and `fly secrets list` shows no `CHROMA_PATH`.
4. **B4 — Downsize VM (D8).** `fly scale memory 256` for quiz-pack-api; observe for OOM over a normal-load window.

---

## Status

- ✅ Recon done (this doc, from #41 S1–S8). Decisions D1–D11 locked (D11 = founder live-code acceptance, 2026-07-06).
- ✅ **Session A — pgvector store surface** (A1, A2) — landed 9b625c2 + d1482bb. New symbols: `PgvectorQuestionStore.upsert/delete/get_all` (async) + `SyncPgvectorStore` passthroughs (`add` added in Session B for the admin import endpoint).
- ✅ **Session B — quiz-agent onto pgvector** (A3–A7) — landed 2026-07-06 (d2ff075, b602b65, e3d129f). `question_store` = `SyncPgvectorStore`; FeedbackService is SQL-only (no `question_store` param); `QuestionMonitor(session_factory=...)` with async `check_health()`; DATABASE_URL mandatory at boot. ⚠️ Found + fixed en route: SQL rating inserts had NEVER worked (required model fields the endpoint can't supply + `feedback_text=` vs `feedback` field mismatch) — model/schema relaxed, empty legacy `question_ratings` table auto-rebuilt on init (fails loud if non-empty).
- ✅ **Session C — teardown + dep drop + deploy** (A8–A13) — landed 2026-07-07 (1b3354b, add24b7, 6a29907, 46a4024 + numpy fix). QuestionStorage = pending-store-only; approve endpoints 410; chroma_client.py + ChromaDBQuestionStore + chromadb dep deleted; ~23 scripts archived to docs/archive/scripts-chroma/; both apps deployed + prod-verified (admin/health 565 q from pgvector; approve 410 w/ key). ⚠️ Found + fixed en route: `numpy` was only a transitive dep via chromadb — prod crash-looped post-deploy until declared explicitly in quiz-shared pyproject.
- 🔶 **Phase B — destructive prod tail**: B1 done 2026-07-07 (full prod backup, 410 rows verified, artifact in `docs/archive/scripts-chroma/chroma_prod_full_backup_2026-07-07.json`; ran via sftp-pull + local chromadb venv since prod image no longer has chromadb). B2–B4 (`[HUMAN]`, destructive) pending founder go.

> When Session A lands, note under Status the exact new symbols (`PgvectorQuestionStore.upsert/delete/get_all` + `SyncPgvectorStore` passthroughs) so B/C import them without re-reading the store.
