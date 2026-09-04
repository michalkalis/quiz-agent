# Issue #170 — Execution plan + ready-to-paste session prompts

**Created:** 2026-09-03 — Phase 6 (Split) of `/prepare-issue`. #170 is **large** (19 atomic tasks across schema, backfill scripts, dedup stage, generation wiring and two measured runbook runs) and **reversibility class `b`** (alembic migration + prod backfills + a prod rating publish), so it is cut into session-sized, independently-committable chunks with **two founder gates**. Each chunk below has a self-contained prompt: open a fresh session, paste the fenced block, go.

> Parent plan: [`issue-170-question-dedup-coverage-steering.md`](issue-170-question-dedup-coverage-steering.md) — read its `## Locked decisions` (1–7, 6a) and `## Resolved design decisions` (D1–D10) once; prompts cite by id and do not restate them.

**Hard rule in every session:** *kvalita otázok sa nesmie zmeniť* (locked 4). All five switches (`COVERAGE_STEERING`, `DEDUP_QA_EMBEDDING`, `ANSWER_CAP`, `DEDUP_GRAYZONE_JUDGE`, `DEDUP_STRICTNESS_PER_CATEGORY`) ship **default OFF** and **no session may enable anything in prod** — that is founder task 170.17 only.

---

## Recon snapshot — what the codebase already gives us

All paths relative to `apps/quiz-pack-api/` unless prefixed `packages/shared/`. `apps/quiz-agent` is not touched at all. Verified 2026-09-03.

**Direct prompt path (the gap):**
- `prompts/question_generation_direct.md` — `{topic_section}` + `{avoid_section}` sit one line after `**Question Type:**`; both collapse to a blank line today.
- `app/generation/prompt_builder.py:233-236` builds `topic_section`; `:239-243` builds `avoid_section` with the fixed heading `**Do NOT repeat or rephrase these questions:**` and a hard `[:10]` cut; `:283` `topics` falls back to `"any"`. **This file must not change** (locked 4, A13).
- `app/orchestrator/stages/generation.py:187` — `topics = [t for t in (ctx.category, ctx.theme) if t] or None`; the `generate_questions(...)` call (~`:195`) never passes `excluded_topics` / `avoid_questions`.

**Dedup / persist / schema:**
- `app/orchestrator/stages/dedup.py` — 4 checks, first match drops: cosine ≥ `0.85` (`:113-125`, `:214-227`), gold Jaccard ≥ `0.80` (`:229-238`), in-batch Jaccard ≥ `0.60` (`:118-124,145-152`), same-fact (`_fact_key` `:153-181`, content Jaccard `0.35`). Thresholds are constructor scalars at `:100-115`. Calibration note `:22-27,60-68` (0.735 dup vs 0.738 non-dup — the gray zone). Helpers `_normalize_answer:255-256`, `_normalize_url:258-262`.
- `packages/shared/quiz_shared/database/pgvector_client.py:292-303` `find_duplicates` — `LIMIT 10` **before** the client-side threshold filter; `_embedding_for:333-338` embeds `question.question` only. Hot path `search():265-290` — do not touch.
- `app/db/models/question.py` — `embedding Vector(1536)` `:33`, `language` nullable `:68`, `ix_questions_pack_id` partial `pack_id IS NOT NULL` `:121-123`. No `subtopic` / `answer_key` / `embedding_qa`.
- Head migration: `f2a91c4b8e57` (`f2a91c4b8e57_order_generation_mode.py`). `persist.py:_question_row_dict:107-120` + `question_to_row` pick new fields up automatically (#167 D6 precedent). ⚠️ shared model changes → `uv pip install -e packages/shared` in every venv or you get "no field" errors.
- `app/orchestrator/stages/topup.py:124` calls `filter_spent_facts` without the threshold arg (`spent_facts.py:130-146` already accepts it; `:52-59` is the import-don't-fork precedent).
- `app/orchestrator/stages/composition.py:41-42,56-67,82-115` caps per-batch per free-text `topic` + T/F format — **different axis**; do not add a subtopic cap there.

**Stage composition (the class-3 boundary):**
- Customer path: `app/worker/tasks.py:92,102` — **must stay byte-identical** (A12).
- Corpus path: `scripts/generate_pack.py:313,328` — the only place that may fill the four constructor params. `:194-213` `_build_dedup_store` (default `noop`, `_NoopQuestionStore.find_duplicates` returns `[]` `:148-160`), `:244` `_judges_enabled` (#169 judges-OFF-in-session), `:12` help text, `--dry-run`, `--target-count`, `--per-topic-cap`, `--topics`, `--dedup-store`.
- `ctx.pack_id` (`app/orchestrator/context.py:43`) is NULL until `PersistStage` (`persist.py:91`) → **never usable as a "this is a pack" predicate**; row-level predicate is `WHERE pack_id IS NULL`.

**Taxonomy / LLM plumbing:**
- `app/generation/classification.py:17-31` `CATEGORIES` — flat 9 ids incl. `entertainment`; aliases `:34-47`. No subtopic layer anywhere. `app/sourcing/topic_pool.py:37-93` is flat/un-keyed — **not reusable**.
- `packages/shared/quiz_shared/llm/factory.py:128-168` role registry (env-overridable `:118-122`), `_REMAP_OPENROUTER:175-203`, session tier map `_SESSION_ALIAS_FOR_ID:243-253` + `LLM_SESSION_MAP`. Cost table `app/llm_usage.py:76-100`, `current_stage` contextvar `:56-58`. Judge seam to copy = `multi_model_scorer.py:616-631` `_get_client` only (D7), **not** the class.
- `app/feature_flags.py:29-30` `_truthy` idiom; `:228-238` `GATE_V2` = the dormant-merged-code precedent.

**Tests / runbook:**
- Dedup: `tests/orchestrator/stages/test_dedup.py` (+`_non_blocking`, `_same_fact`, in-memory fake finder) · live-DB variant `tests/db/test_pgvector_dedup.py` (`TEST_DATABASE_URL`) · persist `tests/orchestrator/stages/test_persist.py` (live DB, `alembic upgrade head` per module) · generation `tests/orchestrator/stages/test_generation.py` · CLI `tests/scripts/test_generate_pack_flags.py`, `tests/scripts/test_generate_pack_session.py` · worker `tests/worker/test_process_order.py` (⚠️ `test_tasks.py` does not exist).
- `tests/conftest.py` pins `LLM_GATEWAY=direct`. Run backend from `apps/quiz-pack-api/` with `uv run --no-sync` (root-build flake); ruff via `uvx ruff check`.
- Zero-cost LLM: `LLM_GATEWAY=session` (#169 runbook `issue-169-session-gateway-subscription-llm.md:63`). Only OpenAI embeddings still cost (cents).
- Replay precedent: `scripts/replay_d21_layers.py`. Rating web: `scripts/rating_page/{build_page,publish_batch,export_ratings}.py` (⚠️ `publish_batch.py:77-82` exits without `--admin-key`; key = `QUIZ_PACK_ADMIN_API_KEY`, **not** `ADMIN_API_KEY`). Prod DB access = `fly proxy 15432:5432 -a quiz-pack-db`.

---

## Locked decisions (carry into every session)

| # | Decision |
|---|---|
| **Locked 1** | Repeated-answer cap is **per category**, never global. |
| **Locked 2** | A duplicate in the corpus is **not a tragedy** — the goal is low waste, not zero tolerance. |
| **Locked 3** | **Custom packs are independent of the global corpus.** No pack ↔ corpus dedup; overlap is fine. |
| **Locked 4** | **Question quality must not drop or change.** Every prompt/pipeline change sits behind a flag, default OFF, enabled only after a blind rated comparison. Prompt outside `{topic_section}`/`{avoid_section}` does not change. |
| **Locked 5** | **Subtopics:** model proposes (~15–20/category), founder signs off once, result is a static file in the repo; no LLM at runtime. |
| **Locked 6 / 6a** | No fixed cap number — per-category configurable and rather loose; `entertainment` gets the **loosest** values, for the answer cap **and** the cosine threshold. |
| **Locked 7** | Out of scope: "tag as duplicate → free replacement" UX, per-user exposure, novelty score in scoring. |
| **D1** | Cell = `(language, category, subtopic)` — **no question type** (cardinality, and `composition.py` already regulates that axis). |
| **D2** | QA embedding = a **second column** `embedding_qa` (+ `_model`), own threshold `DEFAULT_QA_COSINE_THRESHOLD = 0.90`, own SQL-side threshold filter; the original `embedding` stays for retrieval. Fail-loud coverage check only when the flag is ON. Backfill script also fills `answer_key` + `language='en'` (free, no network). |
| **D3** | Weight `1/(count + K)`, `K = max(1, round(N_category / cells))` — degrades to uniform on an empty corpus, self-calibrating. `random.Random(seed).choices`. |
| **D4** | Subtopic is **derived from the allocated cell** — zero extra LLM calls, written at persist. `subtopics.json` schema `{language: {category: [subtopic, …]}}`; binding order: propose → founder sign-off → commit → backfill. |
| **D5** | The four mechanisms are **constructor parameters** (`coverage_allocator`, `strictness`, `qa_embedding`, `grayzone_judge`), filled **only** by `scripts/generate_pack.py`. `app/worker/tasks.py` does not change. Every new query filters `pack_id IS NULL`. Coverage runs on the direct branch only. |
| **D6** | One `DEDUP_STRICTNESS_PER_CATEGORY` profile per category carrying `cosine` (overrides **both** thresholds), `in_batch`, `fact`, `cap`. Exact `fact_key` equality stays global. `TopUpStage` gets the same profile object. |
| **D7** | Gray-zone judge = pairwise "same fact yes/no" for cosine 0.70–0.85, own flag, **independent of `_judges_enabled`**, `GRAYZONE_JUDGE_MAX_CALLS` default 20 + warning on exhaustion. |
| **D8** | Migration = 4 nullable columns + 2 btree indexes on head `f2a91c4b8e57`, no backfill in the migration, **no vector index**. |
| **D9** | HNSW is OUT; instead a one-line `EXPLAIN` check warns if the planner picks an ivfflat index scan. |
| **D10** | Second-order: grounded #167 untouched, packs untouched by construction, `import_questions_json.py` must fill `embedding_qa`, SK/CS (#168) separated by `language` in the key. |

---

## Session breakdown

Binding order: `A → [F1] → B → C → D → [founder prod run] → E → F → G → {H → I} ∥ K → J → L → [F2]`.

| Session | Tasks | Class | Risk | Notes |
|---|---|---|---|---|
| **A — subtopic proposal script** | 170.1 | `a` | Low | Session gateway, mocked tests. Writes nothing to the repo data. |
| *(gate F1)* | **170.2 [F]** | — | — | **Founder sign-off + experiment category fixed.** Nothing after this starts without it. |
| **B — subtopics.json + loader** | 170.3 | `a` | Low | **[blocked on 170.2.]** Commits the approved file + `experiment-category.md`. |
| **C — migration + free/paid backfill** | 170.4 · 170.5 · 170.6 | **`b`** | Med | **Writes prod schema/data → STOP before prod, hand to founder.** Code + live-DB tests locally only. |
| **D — subtopic backfill script** | 170.7 | **`b`** | Med | **[blocked on B merged.]** Same stop rule: `--apply` against prod is a founder step. |
| **E — strictness profile + answer cap** | 170.8 · 170.9 | `a` | Low | `dedup.py` + `topup.py`, one cohesive change. **[parallel-safe]** with F. |
| **F — QA embedding branch + importer** | 170.10 | `a` | Med | pgvector query + persist + importer. **[parallel-safe]** with E. |
| **G — gray-zone judge + replay harness** | 170.11 · 170.14b | `a` | Low | **[blocked on E + F merged]** — the harness injects all four params. |
| **H — coverage map module** | 170.12 | `a` | Med | **[blocked on B.]** Pure module + tests, no wiring. |
| **I — coverage steering wiring + pack isolation** | 170.13 · 170.14 | `a` | Med | **[blocked on E, F, G, H merged.]** Last code session. |
| **J — quality-guard A/B run + report** | 170.15 | `a` | **Med-High** | **[blocked on I merged + the founder prod backfills.]** Real generation (session gateway), **no prod writes**. |
| **K — strictness pass (A26 diff)** | 170.15b | `a` | Med | **[blocked on G merged + founder backfills; parallel-safe with H/I/J.]** Prod DB **read-only** via `fly proxy`. |
| **L — publish both arms to the prod rating web** | 170.16 | **`b`** | **High** | **[blocked on J.]** The only task that writes prod rows. **STOP before executing — founder runs it.** |
| *(gate F2)* | **170.17 [F]** | — | — | **Founder blind rating + per-switch go/no-go.** The only place anything is enabled in prod. |

---

## Human prerequisites

1. **Gate F1 (170.2) — before Session B.** Founder reviews the proposed subtopics JSON from Session A, edits it, and runs the experiment-category query (`SELECT category FROM questions WHERE pack_id IS NULL GROUP BY category ORDER BY count(*) DESC, category ASC LIMIT 1`, prod via `fly proxy 15432:5432 -a quiz-pack-db`). Both outputs go to Session B.
2. **After Sessions C + D merge — founder runs the class-`b` steps against prod:** `alembic upgrade head`, then `scripts/backfill_embedding_qa.py --answer-key-only`, then the paid QA pass (`scripts/backfill_embedding_qa.py`, 170.6 — required before Sessions J and K, both test `DEDUP_QA_EMBEDDING`), then `scripts/backfill_subtopics.py --apply` over the experiment category. Verify A17 (`count = 0` for missing `answer_key`/`language`) and A18. **Sessions J and K do not start before this.**
3. **Before Session L — `QUIZ_PACK_ADMIN_API_KEY`** must resolve from the repo-root `.env` (not `ADMIN_API_KEY`, which 401s). The publish itself is founder-executed.
4. **Gate F2 (170.17).** Founder rates the blind batch, reviews `strictness-keeps.md`, and writes `verdict.md` with a go/no-go **per switch**. Enabling anything in prod happens here and nowhere else.

---

## Ready prompt — Session A (`scripts/propose_subtopics.py`)

```
Work on issue #170 (coverage-driven dedup), Session A only: task 170.1 — the new subtopic-proposal script + its tests. Nothing else in the issue exists yet; do NOT touch dedup.py, generation.py, the schema, or add any feature flag. Commit, push, open one PR.

Why this exists: the whole issue needs a per-category subtopic layer and none exists in the repo (topic_pool.json is flat and un-keyed). The model proposes, the FOUNDER approves (locked 5) — so this script only writes a proposal file the founder reads next.

Read first (already mapped — do not re-map the repo):
- docs/issues/issue-170-execution-prompts.md → "Recon snapshot" + "Locked decisions" (locked 5, D4).
- apps/quiz-pack-api/app/generation/classification.py:17-31 (CATEGORIES, the 9 ids)
- packages/shared/quiz_shared/llm/factory.py:128-168 and :243-253 (roles + session tier map)
- apps/quiz-pack-api/tests/scripts/test_generate_pack_session.py (session-gateway test idiom)

Build (one commit): scripts/propose_subtopics.py — one call per category over CATEGORIES via LLM_GATEWAY=session (zero marginal cost, #169), ~15-20 subtopics each, output to --out JSON in the schema {language: {category: [subtopic, ...]}}. The script writes ONLY the --out file; it never writes into app/generation/ and enables nothing. Test tests/scripts/test_propose_subtopics.py with a mocked client: output validates the schema (three levels, non-empty lists, no duplicates within a category), and a category the model invented that is not in CATEGORIES => exit 1. Intent to encode: "the proposal is never silently trimmed to a subset of the taxonomy".

Done = from apps/quiz-pack-api/: `uv run --no-sync pytest tests/scripts/test_propose_subtopics.py -v` exit 0, full `uv run --no-sync pytest tests/ -q` green, `uvx ruff check` clean. Branch feat/170-propose-subtopics, push, open a PR, address the Claude Code Review findings, squash-merge when green (PR workflow: .claude/rules/shared.md). Then tick 170.1 in docs/issues/issue-170-question-dedup-coverage-steering.md.
Finally: run the script once with LLM_GATEWAY=session, save the proposal JSON into the run dir, and hand it to the founder in-session — task 170.2 is a founder gate and THIS IS WHERE THE AGENT RUN ENDS. Do not commit the proposal as approved, do not start Session B.
```

## Ready prompt — Session B (approved `subtopics.json` + loader)

```
Work on issue #170, Session B only: task 170.3. PRECONDITION: the founder has approved the subtopic proposal (170.2) and given you the approved JSON plus the experiment-category query result. If either is missing, stop and ask in-session — do not approve a proposal yourself and do not guess the category.

Goal: freeze the approved taxonomy into the repo so every later task reads it instead of calling a model (locked 5, D4), and write the experiment category down so it is recorded, not guessed.

Read first: docs/issues/issue-170-execution-prompts.md → "Locked decisions" (locked 5, D1, D4); apps/quiz-pack-api/app/generation/classification.py:17-31.

Build (one commit): app/generation/subtopics.json (the approved file, schema {language: {category: [...]}}) + app/generation/subtopics.py with load_subtopics() (cached, read-only, NO LLM). Same commit: docs/testing/runs/170-coverage-steering/experiment-category.md carrying the founder's query result — winning category, per-category counts, date. Test tests/generation/test_subtopics.py: (a) the committed file matches the schema and covers ALL 9 CATEGORIES with >= 10 subtopics each, (b) the loader fails loud on a missing category. Intent: "runtime never steers by a taxonomy that does not exist".

Done = A1 holds: `uv run --no-sync pytest tests/generation/test_subtopics.py -v` exit 0 AND `jq -e '.en | keys | length == 9' app/generation/subtopics.json` exit 0; full suite green; ruff clean. Branch feat/170-subtopics-file, PR, review, squash-merge. Tick 170.3. Do not start any other task.
```

## Ready prompt — Session C (migration + backfill script — class `b`, STOP before prod)

```
Work on issue #170, Session C only: tasks 170.4, 170.5, 170.6. This is a class `b` session: it produces a schema migration and a corpus backfill script. Write and test everything locally, but DO NOT run alembic or the backfill against PROD — that is a founder step (ready-for-human). Do NOT enable any feature flag anywhere.

Goal: the additive storage the rest of the issue needs (D8) plus a backfill that is free in its default mode (D2), so ANSWER_CAP can later be exercised without a single paid call.

Read first: docs/issues/issue-170-execution-prompts.md → "Recon snapshot" (Dedup/persist/schema) + D2, D8, D9, D10;
- apps/quiz-pack-api/app/db/models/question.py:30-40,60-75,118-132
- apps/quiz-pack-api/alembic/versions/f2a91c4b8e57_order_generation_mode.py (this is head)
- apps/quiz-pack-api/app/orchestrator/stages/dedup.py:255-262 (_normalize_answer) and app/orchestrator/stages/spent_facts.py:52-59 (the import-don't-fork precedent)
- packages/shared/quiz_shared/models/question.py (question_to_row seam) · apps/quiz-pack-api/tests/orchestrator/stages/test_persist.py (live-DB idiom)
- apps/quiz-pack-api/scripts/import_questions_json.py:128-150 (the batching shape to copy)

Build (one commit per task):
1) 170.4 — alembic revision, down_revision = "f2a91c4b8e57", purely additive, NO backfill and NO paid calls: subtopic VARCHAR(64), answer_key VARCHAR(255), embedding_qa Vector(1536), embedding_qa_model VARCHAR(64); indexes ix_questions_lang_category_subtopic, ix_questions_lang_category_answer_key; NO vector index (D9). Mirror the fields on packages/shared/quiz_shared/models/question.py + question_to_row. Downgrade drops columns and indexes. The revision FILENAME must contain 170 (A2 greps alembic/versions/*170*.py). Test tests/db/test_migration_170_columns.py (live DB, alembic upgrade head as in test_persist.py). Remember `uv pip install -e packages/shared` after the shared-model change.
2) 170.5 — scripts/backfill_embedding_qa.py, FREE mode only in this commit: --answer-key-only sets answer_key = _normalize_answer(correct_answer) (IMPORT it from dedup.py, never re-implement) and language='en' where NULL, over `pack_id IS NULL` rows, idempotent, batched. Test tests/scripts/test_backfill_embedding_qa.py: assert ZERO OpenAI calls, second run changes 0 rows, `pack_id IS NOT NULL` rows skipped, and assert __module__ on the imported _normalize_answer (falsifies a silent fork).
3) 170.6 — same script, paid mode: embeds question+answer into embedding_qa (+ embedding_qa_model), only `embedding_qa IS NULL AND pack_id IS NULL`. At the end a one-line EXPLAIN of the dedup query that WARNS if the planner uses an ivfflat index scan (D9). Tests in the same suite: an uncovered row is embedded exactly once, second run 0 calls, simulated ivfflat plan prints the warning.

Done = A2 + A3 hold: `uv run --no-sync pytest tests/db/test_migration_170_columns.py tests/scripts/test_backfill_embedding_qa.py -v` exit 0 (live-DB tests need TEST_DATABASE_URL, never prod), `ls alembic/versions/*170*.py` = exactly 1 file, `grep -ci hnsw alembic/versions/*170*.py` = 0, full suite green, ruff clean. Branch feat/170-migration-backfill, PR, review, squash-merge. Tick 170.4-170.6.
THEN STOP: report to the founder in-session that the prod steps (`alembic upgrade head`, then `--answer-key-only`, then optionally the paid QA pass) are ready for them to run, and that A17 must read 0 afterwards. Do not run them yourself, do not open a fly proxy to write.
```

## Ready prompt — Session D (`scripts/backfill_subtopics.py` — class `b`, STOP before prod)

```
Work on issue #170, Session D only: task 170.7. PRECONDITION: Session B (170.3) is merged, so app/generation/subtopics.json exists. Class `b`: write and test the script, but DO NOT run --apply against PROD — that is a founder step.

Goal: existing corpus rows must carry a subtopic before any coverage steering is measured; without it every cell count is 0, the D3 weighting is provably uniform, and the quality guard would measure "random subtopic", not steering (D4/B2).

Read first: docs/issues/issue-170-execution-prompts.md → D4, D5; apps/quiz-pack-api/app/generation/subtopics.py (from 170.3); scripts/import_questions_json.py:128-150 (batching); docs/issues/issue-169-session-gateway-subscription-llm.md:63 (LLM_GATEWAY=session, zero marginal cost).

Build (one commit): scripts/backfill_subtopics.py — one batched call per category over LLM_GATEWAY=session, classifying existing `pack_id IS NULL` rows into the APPROVED list from 170.3. A value outside that list = fail loud, never a new subtopic. First run writes a JSON preview for the founder; only --apply writes to the DB. Test tests/scripts/test_backfill_subtopics.py: without --apply the DB is unchanged, --apply writes, an out-of-list subtopic => exit 1.

Done = A4 holds: `uv run --no-sync pytest tests/scripts/test_backfill_subtopics.py -v` exit 0, full suite green, ruff clean. Branch feat/170-subtopic-backfill, PR, review, squash-merge. Tick 170.7.
THEN STOP: tell the founder the preview + --apply run over the experiment category (from experiment-category.md) is theirs to execute, and that A18 must hold before Session J. Do not run --apply.
```

## Ready prompt — Session E (per-category strictness + answer cap)

```
Work on issue #170, Session E only: tasks 170.8 and 170.9. PRECONDITION: Session C merged (the columns exist). Do NOT write the coverage module or wire generation (Sessions H/I), do NOT touch app/worker/tasks.py (locked 3, A12), do NOT change prompt_builder.py or the prompt file (locked 4, A13). Both behaviours ship OFF by default.

Goal: locked 1 + 6 + 6a — per-category dedup strictness as ONE profile object (relaxing only the cosine threshold provably does nothing for entertainment, because in-batch Jaccard and the same-fact branch are the binding droppers). Quality must not change: an empty profile must reproduce today's behaviour exactly.

Read first: docs/issues/issue-170-execution-prompts.md → "Recon snapshot" (Dedup) + D5, D6;
- apps/quiz-pack-api/app/orchestrator/stages/dedup.py:52-68,100-181,214-238
- apps/quiz-pack-api/app/orchestrator/stages/topup.py:118-128 and spent_facts.py:130-146
- apps/quiz-pack-api/app/feature_flags.py:29-30 (_truthy idiom) · tests/orchestrator/stages/test_dedup.py

Build (one commit each):
1) 170.8 — parser for DEDUP_STRICTNESS_PER_CATEGORY (kv string, e.g. `entertainment=cosine:0.92,in_batch:0.72,fact:0.45,cap:6`) + a `strictness=None` CONSTRUCTOR parameter on DedupStage and TopUpStage (D5 — no env read inside a stage). dedup.py stops reading self._* scalars and resolves thresholds PER CANDIDATE by q.category at check time; unknown/NULL category falls back to today's global defaults, which do not change. The per-category cosine value overrides BOTH thresholds (question-only and QA, B1); exact fact_key equality stays global. TopUpStage passes profile.fact_jaccard into the existing filter_spent_facts parameter — copy nothing. For a cross-category in-batch pair the STRICTER (lower) of the two profiles decides. Tests in tests/orchestrator/stages/test_dedup.py: empty profile = today's behaviour unchanged; a 0.90 pair passes in entertainment and drops in general; cross-category in-batch follows the stricter profile; a malformed kv string fails at parse.
2) 170.9 — ANSWER_CAP: DedupStage counts (COALESCE(language,'en'), category, answer_key) over `pack_id IS NULL`; above profile.cap (global default ANSWER_CAP_DEFAULT=3) the candidate is dropped with reason `answer_cap` as its OWN counter in StageResult.info (must not merge into cosine drops). Behind the same constructor parameter, disabled by default. Tests in test_dedup.py and tests/db/test_pgvector_dedup.py: cap 3 lets three through and drops the fourth; entertainment cap 6 lets six; the counter is separate; an inserted `pack_id IS NOT NULL` row is NOT counted (A14 leg).

Done = A5 + A6 hold: `uv run --no-sync pytest tests/orchestrator/stages/test_dedup.py -v` exit 0 and `TEST_DATABASE_URL=... uv run --no-sync pytest tests/db/test_pgvector_dedup.py -v` exit 0; `git diff --stat main -- app/worker/tasks.py app/generation/prompt_builder.py prompts/question_generation_direct.md` empty; full suite green; ruff clean. Branch feat/170-strictness-answer-cap, PR, review, squash-merge. Tick 170.8-170.9. Nothing is enabled in prod.
```

## Ready prompt — Session F (QA embedding dedup branch + importer)

```
Work on issue #170, Session F only: task 170.10. PRECONDITION: Session C merged. Parallel-safe with Session E — if E is not merged yet, do not touch its lines in dedup.py; keep your change additive. Do NOT modify find_duplicates or search() (hot path, locked 4). Flag stays default OFF.

Goal: the documented blind spot (dedup.py:22-27 — same fact, disjoint wording: 0.735 dup vs 0.738 non-dup) is not fixable by any question-only threshold, so the QA branch embeds question+answer into a SEPARATE column with its own threshold (D2). It must never silently mix vectors or silently lose recall.

Read first: docs/issues/issue-170-execution-prompts.md → D2, D5, D10;
- packages/shared/quiz_shared/database/pgvector_client.py:265-303,333-338
- apps/quiz-pack-api/app/orchestrator/stages/dedup.py:100-160 · app/orchestrator/stages/persist.py:107-120
- apps/quiz-pack-api/scripts/import_questions_json.py:128-150 · tests/db/test_pgvector_dedup.py

Build (one commit): a NEW query in pgvector_client.py that filters by threshold IN SQL (`WHERE cosine_distance <= 1 - threshold`) and applies LIMIT only ABOVE the filter — find_duplicates is left byte-identical. Predicates `embedding_qa IS NOT NULL AND pack_id IS NULL`, own constant DEFAULT_QA_COSINE_THRESHOLD = 0.90. Behind a `qa_embedding=False` constructor parameter on DedupStage (D5). When ON, DedupStage first FAILS LOUD if `COUNT(*) WHERE pack_id IS NULL AND embedding IS NOT NULL AND embedding_qa IS NULL` != 0, with the instruction to run scripts/backfill_embedding_qa.py, and WARNS on `COUNT(*) WHERE pack_id IS NULL AND language IS NULL`. When OFF: no new query, no guard, zero behaviour change. persist.py and import_questions_json.py fill embedding_qa alongside embedding (second input text in the same batch loop).
Tests: test_dedup.py (branch OFF = no new query and no guard; ON with an uncovered row = fail with the instruction), test_pgvector_dedup.py (an 11th-nearest pair above threshold IS found — exactly what LIMIT-10-before-threshold misses; and an inserted pack row is never returned, A14 leg), test_persist.py.

Done = A7 + A14 hold: `TEST_DATABASE_URL=... uv run --no-sync pytest tests/db/test_pgvector_dedup.py tests/orchestrator/stages/test_dedup.py tests/orchestrator/stages/test_persist.py -v` exit 0; full suite green; ruff clean. Branch feat/170-qa-embedding-dedup, PR, review, squash-merge. Tick 170.10.
```

## Ready prompt — Session G (gray-zone judge + replay harness)

```
Work on issue #170, Session G only: tasks 170.11 and 170.14b. PRECONDITION: Sessions E and F merged — the harness injects all four constructor parameters and they must all exist. Do NOT wire coverage (Session I). Both stay default OFF; no LLM call happens unless the flag is explicitly on.

Goal: (a) close the gray zone 0.70-0.85 with a cheap PAIRWISE "same fact yes/no" verdict — this is not a quality judge and must NOT hang off _judges_enabled (generate_pack.py:244), which #169 keeps OFF in session runs; (b) give sessions J and K a replay harness so a dedup decision can be re-measured over saved candidates with zero generation.

Read first: docs/issues/issue-170-execution-prompts.md → D7 + "Recon snapshot" (LLM plumbing, tests);
- packages/shared/quiz_shared/llm/factory.py:128-168,175-203,243-253 · apps/quiz-pack-api/app/llm_usage.py:56-100
- apps/quiz-pack-api/app/scoring/multi_model_scorer.py:616-631 (adopt this seam ONLY, not the class)
- apps/quiz-pack-api/scripts/generate_pack.py:194-213,244,313,328 · scripts/replay_d21_layers.py (harness precedent)
- apps/quiz-pack-api/tests/scripts/test_generate_pack_session.py

Build (one commit each):
1) 170.11 — new DEDUP_JUDGE role in factory.py + an entry in _REMAP_OPENROUTER and _SESSION_ALIAS_FOR_ID. Pairwise verdict for candidates with cosine 0.70-0.85 through llm_factory.chat_openai + app/llm_usage.py accounting. GRAYZONE_JUDGE_MAX_CALLS default 20 per run; once exhausted, today's behaviour applies (below threshold => passes) PLUS a warning with the count — never silent. Behind constructor parameter `grayzone_judge=None`, default OFF, deliberately allowed under the session gateway. Tests in test_dedup.py (a pair outside the band never calls the judge; a "duplicate" verdict drops with its own reason; after MAX_CALLS no call plus a logged warning) and tests/scripts/test_generate_pack_session.py (the flag survives session mode — mirror of the #169 quality-panel test).
2) 170.14b — scripts/replay_dedup_json.py: replays a JSON candidate file through DedupStage with NO generation at all, injecting all four constructor parameters and env flags the same way generate_pack.py does. Test tests/scripts/test_replay_dedup_json.py: same input + same thresholds reproduce the original run's decisions; the generator is never called; `--dedup-store noop` is REFUSED fail-loud (otherwise a replay would also only measure in-batch).

Done = A15 + A16b hold: `uv run --no-sync pytest tests/orchestrator/stages/test_dedup.py tests/scripts/test_generate_pack_session.py tests/scripts/test_replay_dedup_json.py -v` exit 0; full suite green; ruff clean. Branch feat/170-grayzone-judge-replay, PR, review, squash-merge. Tick 170.11 and 170.14b.
```

## Ready prompt — Session H (coverage map module)

```
Work on issue #170, Session H only: task 170.12. PRECONDITION: Session B merged (subtopics.json + loader). Build the MODULE ONLY — do NOT wire it into GenerationStage or generate_pack.py, that is Session I. Parallel-safe with E/F/G.

Goal: positive cell allocation from a coverage map (D1/D3). It must degrade to uniform on an empty corpus by construction, and it must NEVER steer blind: a category with no subtopic-tagged rows is a missing prerequisite, not a zero.

Read first: docs/issues/issue-170-execution-prompts.md → D1, D3, D4, D5, D9;
- apps/quiz-pack-api/app/generation/subtopics.py (170.3) · app/db/models/question.py:118-132
- apps/quiz-pack-api/app/generation/prompt_builder.py:239-243 (the hard [:10] cut the avoid-list must pre-empt)
- packages/shared/quiz_shared/database/pgvector_client.py (query idiom) · tests/generation/ (test idiom)

Build (one commit): app/generation/coverage.py — one `GROUP BY COALESCE(language,'en'), category, subtopic` over `pack_id IS NULL`; weights 1/(count + K) with K = max(1, round(N_category / cells)); selection via random.Random(seed).choices(...). FAIL LOUD when the requested category has not a single row with a non-empty subtopic (B2) — never steer blind, never silently degrade to uniform. Inherit the one-line EXPLAIN ivfflat check + warning (D9). The module also returns the avoid-list: deterministically ordered (newest rows first, tie-break id) and TRIMMED TO <= 10 inside the module, because prompt_builder.py:243 hard-cuts at 10 and an unordered selection would be random.
Tests tests/generation/test_coverage.py: fixed seed + fixed counts => fixed cell list; all counts 0 => distribution statistically indistinguishable from uniform; a cell far above K => its share drops; category without subtopics => fail loud; the avoid-list is identical across two runs on the same input and has <= 10 items; an inserted `pack_id IS NOT NULL` row appears in NO count and NOT in the avoid-list (A14 leg).

Done = A8 + A9 + A14 hold: `uv run --no-sync pytest tests/generation/test_coverage.py -v` exit 0; full suite green; ruff clean. Branch feat/170-coverage-map, PR, review, squash-merge. Tick 170.12.
```

## Ready prompt — Session I (COVERAGE_STEERING wiring + pack isolation gate)

```
Work on issue #170, Session I only: tasks 170.13 and 170.14. PRECONDITION: Sessions E, F, G, H merged — all four constructor parameters and the coverage module must already exist. This is the last code session. HARD RULES: prompt_builder.py and prompts/question_generation_direct.md must stay byte-identical (locked 4, A13); app/worker/tasks.py must stay byte-identical (locked 3, A12); every flag default OFF and nothing is enabled in prod.

Goal: fill the two placeholders that are empty today, from the coverage map, on the direct branch only — and prove by construction (not by discipline) that a misconfigured prod secret can never turn any of this on for a customer pack.

Read first: docs/issues/issue-170-execution-prompts.md → D4, D5, D6 + "Recon snapshot" (stage composition);
- apps/quiz-pack-api/app/orchestrator/stages/generation.py:183-203 · app/orchestrator/stages/persist.py:85-120
- apps/quiz-pack-api/app/generation/prompt_builder.py:233-243 (READ ONLY — the avoid slot's fixed heading is why we send QUESTION TEXTS, never answers)
- apps/quiz-pack-api/scripts/generate_pack.py:194-213,300-340 · app/worker/tasks.py:85-110 (READ ONLY)
- apps/quiz-pack-api/tests/orchestrator/stages/test_generation.py · tests/scripts/test_generate_pack_flags.py · tests/worker/test_process_order.py

Build (one commit each):
1) 170.13 — GenerationStage gets `coverage_allocator=None` (default = today's behaviour). When on: generation.py:187 ADDS the allocated subtopic to today's [category, theme] (the category is NOT removed, so arm B differs from arm A only by the added steering); avoid_questions = <= 10 QUESTION TEXTS of that cell (not answers); excluded_topics stays None. PersistStage writes the allocated subtopic (D4 — zero LLM calls); OFF => NULL. Runs only on the direct branch (ctx.direct_generation) — grounded #167 carries its own topics via SourcingStage._forced_topics. scripts/generate_pack.py reads the four env flags + DEDUP_STRICTNESS_PER_CATEGORY + CLI switches (incl. --coverage-seed) and injects all four constructor parameters. ANSWER_CAP has no parameter of its own: the cap lives in the strictness profile (profile.cap), the flag only toggles its enforcement. Tests: OFF => generate_questions(...) kwargs identical to today; ON => topics carries category AND subtopic and avoid_questions has <= 10 question texts; a grounded run never calls the allocator.
2) 170.14 — the isolation gate (no production behaviour change; it is a gate, not a feature). tests/worker/test_process_order.py::test_worker_stages_use_default_170_parameters: stages composed in app/worker/tasks.py:92,102 carry all four parameters at their defaults EVEN WITH all four env flags set to 1 and DEDUP_STRICTNESS_PER_CATEGORY populated. Do not assert the `pack_id IS NULL` predicate as a string over SQL in a foreign suite — such an assert cannot fail; the behavioural legs already live in test_coverage.py, test_dedup.py and test_pgvector_dedup.py. The third leg is a diff, not a test.

Done = A10 + A11 + A12 + A13 + A16 hold: `uv run --no-sync pytest tests/orchestrator/stages/test_generation.py tests/scripts/test_generate_pack_flags.py tests/worker/test_process_order.py -v` exit 0; `git diff --stat main -- app/worker/tasks.py app/generation/prompt_builder.py prompts/question_generation_direct.md` prints nothing; /verify-api reports 0 mismatches; full suite green; ruff clean. Branch feat/170-coverage-steering, PR, review, squash-merge. Tick 170.13-170.14.
```

## Ready prompt — Session J (quality-guard A/B run + report)

```
Work on issue #170, Session J only: task 170.15. PRECONDITIONS, all mandatory: Session I merged; 170.3 committed; the founder has run backfill_subtopics.py --apply over the experiment category (A18), the answer_key/language backfill (A17), and the PAID embedding_qa backfill (170.6) — step 3 runs with DEDUP_QA_EMBEDDING ON and DedupStage fail-louds unless `count(*) WHERE pack_id IS NULL AND embedding IS NOT NULL AND embedding_qa IS NULL == 0`. If any is missing, STOP and ask in-session — do not run a partial guard and do not lower the bar. This session writes NOTHING to prod (both arms are --dry-run) and enables NOTHING in prod.

Goal: locked 4 is a hard gate — prove that COVERAGE_STEERING does not change quality, and get a directional read on waste. Only COVERAGE_STEERING changes question CONTENT; the other three only drop candidates, so they are validated by counting, not by rating.

Read first: docs/issues/issue-170-question-dedup-coverage-steering.md → the whole "## Quality guard" section and acceptance rows A19-A21, A25 (those are your done-criteria verbatim); docs/issues/issue-170-execution-prompts.md → "Recon snapshot" (CLI); docs/testing/runs/170-coverage-steering/experiment-category.md (the category — never guess it).

Run from apps/quiz-pack-api/, LLM_GATEWAY=session (zero marginal cost, #169; OpenAI embeddings cost cents):
1) Both arms `--dry-run --dedup-store pgvector` with DATABASE_URL set (prod read-only via `fly proxy 15432:5432 -a quiz-pack-db`), N = 30 per arm, SAME category, SAME model (canonical Fable 5), SAME prompt file. Arm A = flags OFF, arm B = COVERAGE_STEERING=1, the other three dedup flags OFF. --dedup-store defaults to noop and _NoopQuestionStore returns [] — with noop, metric 2 measures only in-batch and is INVALID; the run must refuse to report metric 2 in that case.
2) `SELECT count(*) FROM questions;` before arm 1 and after arm 2 must match (A19) — both numbers go in the report. Nothing is written to `questions` between the arms.
3) Re-scoring pass: run scripts/replay_dedup_json.py (from 170.14b) over the SAME saved dry-run candidates with DEDUP_QA_EMBEDDING + ANSWER_CAP + DEDUP_GRAYZONE_JUDGE ON — no new generation, no new model call — to produce the dropped-sample-with-pair and the judge call count. (The false-KEEP sample for A26 is produced by 170.15b, not here.)
4) Same commit: fix the misleading help text at scripts/generate_pack.py:12 (today's "--dry-run = no Postgres required" must say corpus dedup requires --dedup-store pgvector + DATABASE_URL), and write docs/testing/runs/170-coverage-steering/README.md.

Done = A19-A21 + A25 hold: docs/testing/runs/170-coverage-steering/report.md exists and carries metric 1, metric 2, arm order, the drop-reason breakdown, the dropped sample with pairs, the judge call count, and per arm a validity line (model, prompt file path, category, N = 30) — all four identical across arms or the guard is INVALID and the report must say so. Metric 2 stays empty and fail-loud if the store was noop. Commit the run dir, branch feat/170-quality-guard, PR, review, squash-merge, tick 170.15.
Then report the numbers to the founder in-session. Do NOT publish anything to the rating web (Session L) and do NOT enable any flag. If metric 1 or metric 2 fails, that is a valid terminal state: report it with numbers, leave the flags OFF; never raise N or relax a bar on your own.
```

## Ready prompt — Session K (strictness pass — the A26 "what did relaxing keep" diff)

```
Work on issue #170, Session K only: task 170.15b. PRECONDITIONS: Session G merged (the replay harness), the founder's answer_key backfill has run, and the PAID embedding_qa backfill (170.6) has run — the diff must be annotatable with the `cosine-qa` drop branch. Parallel-safe with Sessions H/I/J. Prod DB is READ-ONLY here: `fly proxy 15432:5432 -a quiz-pack-db`, stop the proxy when done. Nothing is written to `questions`; nothing is enabled in prod.

Goal: DEDUP_STRICTNESS_PER_CATEGORY is the only change that RELAXES dedup, so "no false drop" cannot validate it — the founder needs the inverse: everything the relaxed profile KEPT that the global thresholds would have dropped. The guard run (170.15) cannot produce this: its dedup flags are OFF and it runs on the experiment category, where no override exists.

Read first: docs/issues/issue-170-question-dedup-coverage-steering.md → task 170.15b and acceptance row A26 (verbatim done-criteria) + D6; docs/issues/issue-170-execution-prompts.md → "Recon snapshot" (Dedup).

Entry condition (a missing input, not an empty result): `SELECT count(*) FROM questions WHERE pack_id IS NULL AND category = 'entertainment';` must be >= 21. If it is lower, DO NOT RUN — report and stop.

Run: candidates = the existing entertainment questions from the #167 pilot (docs/testing/runs/167-entertainment-pilot/pilot_167_r2.json, else pilot_167.json), replayed through DedupStage with scripts/replay_dedup_json.py in `--dry-run --dedup-store pgvector`. TWICE over the SAME input, with DEDUP_GRAYZONE_JUDGE=0 in BOTH runs (otherwise the judge mixes its own verdicts into the diff): once with an empty profile (global thresholds) and once with DEDUP_STRICTNESS_PER_CATEGORY=entertainment=cosine:0.92,in_batch:0.72,fact:0.45,cap:6.

Write docs/testing/runs/170-coverage-steering/strictness-keeps.md carrying THE WHOLE DIFF, not an excerpt: every pair/candidate the relaxed profile kept and the global thresholds would have dropped, annotated with the branch that would have dropped it (cosine-q / cosine-qa / in-batch / fact-content / answer-cap) and its score. For answer-cap keeps, LIST THE SIBLING ROWS sharing the answer_key (id + question text), not just a count — without them a keep cannot be judged. The file must also name the category that carried the override, record the ACTUAL measured count(*) value from the entry condition, and quote BOTH env lines verbatim (DEDUP_STRICTNESS_PER_CATEGORY=..., DEDUP_GRAYZONE_JUDGE=0) — once the fly proxy is gone these are the only falsifiable traces. State explicitly that ~21 of the 54 pilot rows are already published in the corpus and self-match in BOTH arms, so a thin diff means a small effective input, not a weak profile. The cosine band 0.85-0.92 is an ANNOTATION, never a filter (an in-batch keep can sit at 0.78 and an answer_cap keep has no pair at all).
Fail-loud binds ONLY to an empty diff with the entry condition met: that means "the profile changed nothing on this input" — say it explicitly, leave the switch OFF pending a larger input, and never report it as "no false keeps" or as a failed run.

Done = A26 holds: strictness-keeps.md is non-empty and carries all of the above. Commit the run dir, branch feat/170-strictness-pass, PR, review, squash-merge, tick 170.15b. Report to the founder in-session; the verdict on this switch is theirs (170.17), read from this file, not from the rating.
```

## Ready prompt — Session L (publish both arms to the prod rating web — class `b`)

```
Work on issue #170, Session L only: task 170.16. PRECONDITION: Session J finished, both arm JSON outputs exist, and the corpus stayed frozen between them (A19). This is the ONLY task in the issue that writes prod rows. Class `b`: prepare and verify everything, then STOP — the founder executes the prod commands. Nothing is enabled in prod by this task.

Goal: get one blind, shuffled, unlabelled rating batch in front of the founder (same procedure as the #168 blind batches / PR #70), so metric 1 is a real blind comparison. The founder must not be able to tell which question came from which arm.

Read first: docs/issues/issue-170-question-dedup-coverage-steering.md → task 170.16 + acceptance row A22; docs/issues/issue-170-execution-prompts.md → "Recon snapshot" (rating web) + "Human prerequisites" item 3.
- apps/quiz-pack-api/scripts/import_questions_json.py (the #158 fail-closed gate still applies)
- apps/quiz-pack-api/scripts/rating_page/build_page.py and publish_batch.py:70-90 (SystemExit without --admin-key)

Prepare: the exact import + build_page + publish_batch command lines (base-url https://quiz-pack-api.fly.dev, --rater michal, --save-mapping into docs/testing/runs/170-coverage-steering/), shuffled and unlabelled across both arms, with the arm<->question mapping saved into the run dir. Verify offline with build_page.py that the page renders and the mapping is complete. QUIZ_PACK_ADMIN_API_KEY (NOT ADMIN_API_KEY, which 401s) must resolve from the repo-root .env — check, do not substitute.

Done = the commands, the mapping file and the run-dir commit are ready and reviewed, and the founder has been handed the exact commands to run. After the founder's run, A22 must hold: publish_batch.py exit 0 printing a batch_id, `curl -s -o /dev/null -w '%{http_code}' "https://quiz-pack-api.fly.dev/web/rate/<batch_id>?rater=michal"` = 200, and a non-empty mapping file. Branch feat/170-publish-guard-batch, PR, review, squash-merge, tick 170.16.
THIS IS WHERE THE AGENT RUN ENDS — the founder rates next (170.17) and is the only one who may switch anything on. Do not enable a flag, do not set a prod secret.
```

## Status

| Session | Tasks | State |
|---|---|---|
| A — subtopic proposal | 170.1 | ⬜ |
| gate F1 | 170.2 | ⬜ |
| B — subtopics.json + loader | 170.3 | ⬜ |
| C — migration + backfill (`b`) | 170.4-170.6 | ⬜ |
| D — subtopic backfill (`b`) | 170.7 | ⬜ |
| E — strictness + answer cap | 170.8-170.9 | ⬜ |
| F — QA embedding branch | 170.10 | ⬜ |
| G — gray-zone judge + replay harness | 170.11 · 170.14b | ⬜ |
| H — coverage map module | 170.12 | ⬜ |
| I — steering wiring + isolation gate | 170.13-170.14 | ⬜ |
| J — quality-guard A/B run | 170.15 | ⬜ |
| K — strictness pass (A26) | 170.15b | ⬜ |
| L — publish rating batch (`b`) | 170.16 | ⬜ |
| gate F2 | 170.17 | ⬜ |

When a session lands, add a short *"Session X delivered — exact symbols for Y"* note here so the next session imports the real names instead of guessing.
