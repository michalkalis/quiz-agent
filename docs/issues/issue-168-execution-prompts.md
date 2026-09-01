# Issue #168 — Execution plan + ready-to-paste session prompts

**Created:** 2026-09-01 — Phase 6 (`/split-issue`) of `/prepare-issue`. #168 is **large** (26 atomic tasks, 7 stages, 4 subsystems) and **sensitive** (`b`: additive Postgres migration on the shared `quiz-pack-db` cluster; several `c` prod deploys + a serve-path cutover), so it is split into session-sized, independently-committable chunks. Each chunk below has a self-contained prompt: open a fresh session, paste the fenced block, go — **no re-mapping of the codebase required**.

> Parent plan: [`issue-168-batch-translation-pipeline-sk-cs.md`](issue-168-batch-translation-pipeline-sk-cs.md) (locked decisions 1–8, DD1–DD16, tasks T1–T26, 24 acceptance criteria). Binding external input: [`../research/research-translation-pipeline-sk-cs.md`](../research/research-translation-pipeline-sk-cs.md).
> Gates already passed: Phase 3 **READY + SOUND 0.87**, Phase 5 **Gate A READY (3×) + Gate B SOUND 0.88**.

**⚠️ Loop eligibility.** Ralph runs class `a` only. Sessions marked *loop-eligible: no* are founder-gated or human-triggered — they must be driven interactively. Every loop-eligible session below **stops before** the next founder gate; none of them deploys, migrates, or changes what prod serves.

---

## Recon snapshot — what the codebase already gives us

*(Compressed from the parent plan's `## Recon (Phase 1)` §1–§10 — go there for the full reading. Anchors spot-verified 2026-09-01.)*

**`packages/shared` — the shared store, read by both services**

- `quiz_shared/database/pgvector_client.py`: `questions_table:74-107` (discrete typed columns, `provenance` JSONB not filterable) · `add:167` (`ON CONFLICT DO NOTHING`) · `upsert:185` (the shared write path) · `count:238-244` · `search:270-290` (`WHERE … ORDER BY embedding <=> q LIMIT n`) · `_build_where:113-134` — flat equality / `$in` / `$ne` on **one column**, no joins.
- `quiz_shared/llm/factory.py`: `gateway():263-270` (`LLM_GATEWAY` = `direct`|`openrouter`) · `_REMAP_OPENROUTER:168-196` (direct ids → OpenRouter slugs, covers `claude-*` + `google/gemini-*`) · `resolve_model:273-285` · native `anthropic.AsyncAnthropic` `:320-345` · role `ANSWERABILITY = deepseek-v4-flash` `:160`. **No batch surface, no DeepL client, no Google SDK anywhere.**

**`apps/quiz-agent` — the serving hot path**

- `app/serializers.py`: `build_question_translation:98,109` (EN returns `None` at `:109`) · `translated_question_view:192-213` (overrides stem/options/explanation/headline/answer, **not** `alternative_answers`) · `translated_question_payload:219,235` · `question_to_dict_translated:244`.
- `app/quiz/flow.py`: `QuizFlowService.__init__:112,120` · candidate commit `:266-271` · `:279` · EN answer path `:499-504` · `:492-493` translation branch · `_translate_correct_answer:509-521` (deleted in T24).
- `app/retrieval/question_retriever.py`: `count:62-64` · `get_next_question:110-136` (expired filter `:118-119` primary, `:129` on fallback output, ladder re-entry `:121,125-127`, `_handle_no_candidates` `:130-131`) · `_build_metadata_filters:208-269` (**pack branch early-returns `:234-241`**, channel `review_status` `:246-250`, normal branch `:251-267`) · `_fallback_retrieval:300-376` (packs `[]` `:331-332`, rung 3 drops `difficulty` `:368-376`) · `_handle_no_candidates:378-400`.
- `app/api/routes/quiz.py:124-162` — `/start` exhaustion accounting (global count `:124-126`, 0.8 graceful branch `:129-138`, `filter_lines` `:146-156`, 500 `:140-162`).
- `app/api/deps.py:60-62` language shape-only validator (`^[a-z]{2}$`) · `get_question_store:458` (already exists) · `get_translation_service:462-463` (deleted in T24).
- `app/translation/` — the dying serve-time stack: `translator.py:51` (`translate_question:161`, `translate_question_payload:324`, `translate_feedback:444`), `store.py:14-24,26,35` (SQLite, keyed by **source text**, no `question.id`, no alembic). ⚠️ `__init__.py` also re-exports `get_feedback_message` still used by `app/api/routes/tts.py:211-213` — edit the module, never delete the directory.
- Alembic chain head `0007_feedback_table` (auth/users/subs/feedback only — **no questions tables here**).
- `fly.toml:26` / `fly.staging.toml:27` = `TRANSLATION_CACHE_URL`; ⚠️ the `/data` mount (`fly.toml:54-56`, `fly.staging.toml:55-57`) is **shared** with `RATINGS_DATABASE_URL` and `TTS_CACHE_DIR` — never remove it.

**`apps/quiz-pack-api` — pipeline, verification, ratings, migrations**

- Alembic head **`f2a91c4b8e57`** (`f2a91c4b8e57_order_generation_mode.py`) — verified head on 2026-09-01 (no child revision); naming = 12-hex + slug. Re-verify before writing T11.
- `app/verification/answerability.py`: `AnswerabilityChecker:101`, `check():138`, `AnswerabilityResult:44-48`, `_PROMPT:36-41` (genuinely blind), deterministic comparators `_mcq_answers_match:85` / `_text_answers_match:67`, fail-**safe** `:151-155`, open-shape skip `:175-178`. ⚠️ `_normalize:51-56` strips every non-`[a-z0-9]` char → destroys SK/CS diacritics; `_ARTICLES:34` is English.
- `app/verification/fact_verifier.py:69-83` `VerificationResult` + fail-**closed** `_held():337-345` — the contract `judge.py` adopts. `app/verification/shape_classifier.py:45` — the single-attribute classifier shape `regional.py` copies.
- `app/scoring/craft_guards.py` — source-craft guards only (`_IMPERIAL_ALWAYS_RE:66`, `_METRIC_RE:74,81`, `stem_leak_reason:127`, `long_answer_reason:182`, `units_reason:208`, `undated_record_reason:239`, `true_false_key:260`, `tf_imbalance_excess:289`). Reusable as **extraction regexes only** — none compares a source/target pair.
- `app/orchestrator/stages/answerability.py:23,26,34,67-73` — fans the checker, **persists nothing**. No orchestrator stage is added by this issue.
- Ratings (#154, reused as-is): `app/api/v1/ratings.py:53,84,118,161,197` · `ratings_schemas.py:26` (`Rating.extra["flags"]`), `:29-42` (`extra="forbid"`) · `app/db/models/rating.py:48,68` · `app/web/rate.py:32,40` · importer `scripts/rating_page/publish_batch.py:42-65,85` (`--arm NAME=path.json` repeatable, `--seed N`, `--title`, `--base-url`, `--rater`) · `build_page.py:71`. Auth `X-Admin-Key` / `ADMIN_API_KEY` (`app/api/deps.py:104,216`); the rating page itself is unauthenticated (batch UUID = capability).
- Eval-harness pattern: `scripts/factcheck_eval_166.py` — `done_qids():90` (JSONL resume), `cmd_report:367-401` (recall / false-alarm / cost scorer), subcommands `:405-420`. ⚠️ Its `BAD_QIDS:48` are **factual** errors in English questions — never reuse those qids for a translation judge (DD6).
- Script idiom (#167 precedent `scripts/source_facts.py:23-27,37,42,50-62,85-88`): `uv run --no-sync python scripts/<name>.py …` run **from `apps/quiz-pack-api/`**, `sys.path.insert` at top, argparse, fail-loud thin-yield gate.
- `app/cost_tracking.py:34,38-39,42-55,58-65,68-72,75-99` — order-scoped `ContextVar` tracker; `fetch_openrouter_usage:75-99` returns `None`, never a fake `0`. Reuse the *method*, not the tracker (DD9).
- `app/db/models/question.py:75,120,129,157,175-177` (`GenerationProvenance`; `category` free-form `str`; difficulties `easy|medium|hard`); categories = `CATEGORY_TAXONOMY` 6 values (`apps/quiz-agent/app/api/admin.py:154-161`). **No (category × difficulty) crosstab exists** — T17 computes it.

**iOS (`apps/ios-app`, Xcode project "Hangs")**

- `Hangs/Hangs/Models/Language.swift:18-31` `supportedLanguages` (all 10, exonym + native), `default:34`, `forCode:39-41`. Picker sites: `Views/SettingsView.swift:291`, `Views/HomeView.swift:294`, `Views/OrderPack/OrderPackFormStep.swift:65`.

**Envs / infra**

- Fly apps: `quiz-agent-api`, `quiz-agent-api-staging`, `quiz-pack-api`, `quiz-pack-api-staging`. Prod and `quiz_pack_staging` are **separate logical DBs on one cluster `quiz-pack-db`**, each with its own alembic version table. `DATABASE_URL` is a Fly secret, never in `fly.toml`.
- Migrate **before** deploy; run alembic from the repo root (`project_backend_arch_review_2026_07_18`). Prod DB access from a laptop = `fly proxy` (memory `project_rating_infra_2026_08_14`).

**⚠️ Gotchas that bite**

1. `_build_where` **silently skips unknown filter keys** (`:118-122`) — for a *gate* that means serving everything. DD2 makes it raise.
2. `questions_table` is a shared explicit declaration; code declaring `approved_languages` against a DB without the column **500s every retrieval, EN included**. Both logical DBs migrate first (T11 → T12).
3. Nothing in this repo has ever called a provider Batch API — treat DD7's smoke test as a real risk, not a formality.
4. The pack branch early-returns (`question_retriever.py:234-241`); the gate key must **never** be added there, or a paid bundle can be emptied.
5. `uv run --no-sync` (root build flake, memory `project_uv_run_root_build_flake`); `uvx ruff check` for lint.

---

## Locked decisions (carry into every session — full text in the parent plan)

| # | Decision (one-line lift; read the full DD before implementing) |
|---|---|
| **LD0** | **Spend cap (founder 2026-09-01): any single step whose estimated OpenRouter spend exceeds $5 STOPS and asks the founder interactively with a cost estimate before running.** Below $5, proceed autonomously but record the spend (DD9 cost tracking). Applies to every session here — arm test, batch translate, judge validation, competence pre-checks. |
| **LD1–LD8** | Founder 2026-08-31, not re-litigable: batch pre-translation via Batch API, incremental · **serve only approved**, no runtime fallback · per-(question,language) gate = guards + blind answerability + MQM-Quiz judge + regional flag · phase-1 arm test picks the model per language · human review of critical/flagged/random via the rating web · translations are first-class stateful data (SQLite cache + `TRANSLATION_PROMPT_VERSION` replaced) · `language_dependent` (#128) respected · native generation out of scope. |
| **DD1** | Serving gate = `questions.approved_languages TEXT[]` + GIN, filtered with a new `$contains` → `@>`; derived index written only by the pipeline; added **only** for `session.language != "en"`; never relaxable in the fallback ladder; pack branch untouched. Drift control = `reconcile` (consistency leg + `source_hash` staleness leg). Index honesty: exact only while the planner seq-scans — verify with `EXPLAIN ANALYZE` (T25). |
| **DD2** | `_build_where` **raises `ValueError`** on a key absent from `questions_table.c` (a typo'd gate key = serving everything). Plus a behavioural test that a SK filter dict actually excludes an untranslated question. |
| **DD3** | `question_translations` (one live row per `(question_id, language)`, statuses `pending/approved/rejected/stale`, full serve payload **including `alternative_answers`**, provenance incl. `source_hash`, `verification` JSONB) + append-only `question_translation_corrections`. Additive migration on the quiz-pack-api chain. `source_hash` = sha256 over canonical JSON of `{question, possible_answers, correct_answer, alternative_answers, explanation}`; demotion happens **inline in `upsert`**, `reconcile` is the backstop. |
| **DD4** | Clean cut on serving, **no dual-path flag**; safety = ordering (migrate both DBs → deploy inert → arm verdict → corpus to coverage → flip). Coverage gate = 18 cells (6 categories × 3 difficulties), 3 bars (cell ratio 95 %, cell floor 10, category floor `min(30, ceil(0.95 × eligible EN))`), `en_starved`/`en_starved_category` escapes, `--waive` per run, non-zero exit listing failing cells. Numbers are **defaults pending T18 calibration**. Per language. |
| **DD5** | Both hot-path call sites die; approved row is the single source for display **and** grading (`alternative_answers` copied into `translated_question_view`). Drift skip lives in the **retriever** (`get_next_question`), never the serializer. |
| **DD6** | Judge validated on purpose-built translation-defect sets — `docs/testing/translation-defect-reference-sk.json` (~20) and `-cs.json` (~12), **not** the #166 factual qids. Bar per language: every `critical` caught, zero `critical` false positives on controls. CS carries an extra founder 20-sample spot-check before its cutover. |
| **DD7** | One runner `apps/quiz-pack-api/scripts/translate_corpus.py` (`plan\|submit\|poll\|ingest\|verify\|review-export\|report\|reconcile`); JSONL resume under `data/translation_jobs/<job_id>.jsonl`; `plan` is the default, `submit`/`verify` need explicit flags + `--limit`; DB write only at `ingest`; partial failure exits non-zero. OpenRouter batch first, native Anthropic Message Batches as fallback, **proven by a 5-request smoke before anything is built on it**. DeepL calls its own SDK synchronously. |
| **DD8** | Arm test is file-based → runs before the migration gate. 4 arms × ~35 questions × sk+cs → blind rating batch via `publish_batch.py`. Output = founder model-per-language verdict. No model change without eval data + approval. |
| **DD9** | Cost per batch recorded in the job JSONL (OpenRouter `/credits` delta; DeepL by characters), per-question share persisted to `question_translations.cost_cents`; an unavailable usage read stores `None`, never `0`. |
| **DD10** | SQLite cache is discarded as content, mined once as **defect material** (T5), then removed at cutover (T25). |
| **DD11** | EN sessions byte-identical before and after — asserted, not assumed. |
| **DD12** | Gate = new package `apps/quiz-pack-api/app/translation_verification/`: `guards.py` (built, always enforcing) · `answerability.py` (extends the existing checker) · `judge.py` (built, fail-closed) · `regional.py` (built, flag-only, never drops). Pure functions of `(source_question, translated_draft, language)`, called **only** by the runner — no orchestrator stage. |
| **DD13** | Answerability is a **delta** check: EN control + target leg in the same submission; `en_pass ∧ ¬tgt_pass` = `translation_flip` (critical, blocks); `¬en_pass` = `control_fail` (never blames the translation); either leg unavailable = row stays `pending`. Competence pre-check (>10 % flip on known-good ⇒ escalate the model) runs **after** DD8's verdict. |
| **DD14** | Language visibility = env-driven list in `packages/shared/quiz_shared/languages.py` (`SERVABLE_QUIZ_LANGUAGES` default `en,sk,cs`; `PACK_ORDER_LANGUAGES` default `en`), one `GET /api/v1/languages`, both services enforcing through the same helper. iOS filters the picker from a launch-time fetch with a compiled fallback. **Client-first ordering:** backend ships soft-failing (T21) and hardens only after the gated build is on the device (T26). |
| **DD15** | Packs stay **English-ordered** in this issue; native-language pack generation is a follow-up issue (founder 2026-09-01, already in TODO). The gate key is never added to the pack branch; legacy non-EN pack rows are exempt from the drift skip. |
| **DD16** | `/start` exhaustion accounting uses the **same** language gate as serving (one shared filter helper for `search` + `count`) → a finished SK/CS pool ends with **409 `reset_history`**, never a 500; the honest 500 and the empty-DB message become language-aware. |

**Coordination note.** #167 (entertainment questions) keeps adding/refreshing English rows; every such edit flows through `PgvectorQuestionStore.upsert`, so DD3's inline demotion is what keeps their translations honest. The pack-native-generation follow-up (TODO, founder 2026-09-01) is the successor to DD15 — do not pre-build it here.

---

## Session breakdown

Dependencies name **merged** sessions. `∥` = may run in parallel with the listed sessions.

| Session | Tasks | Class | Loop-eligible | Gate before | Depends on / ∥ |
|---|---|---|---|---|---|
| **A** — Arm tooling (batch adapter + arms script) | T1 (code half), T2, T3 | `a` (T1 secret half = HP-1) | **yes** | HP-1 | — · ∥ C, D, G, O |
| **B** — Arm publish + founder verdict | T4 | `a` `[HUMAN]` | no | — | A · ends at **HG-2** |
| **C** — Translation-defect reference sets | T5 | `a` | **yes** | — | — · ∥ A, D, G, O |
| **D** — Guards + delta answerability | T6, T7 | `a` | **yes** | — | — · ∥ A, C, E-prep, G, O |
| **E** — MQM judge + regional + judge eval to the DD6 bars | T8, T9 | `a` | **yes** | — | C · ∥ A, D, G, O |
| **F** — Answerability competence pre-check | T10 | `a` | **yes** | HG-2 | B, D |
| **G** — Migration + models (staging → gate → prod) | T11 | `b`/`c` `[HUMAN gate]` | no | — | — · contains **HG-3** |
| **H** — Shared store: `$contains`, fail-loud, `get_translations`, `source_hash` | T12, T13 | `a` | **yes** | HG-3 done | G |
| **I** — Inert prod deploy | T14 | `c` | no | — | H |
| **J** — Runner core (`plan\|submit\|poll\|ingest`) + cost | T15 | `a` | **yes** | — | G, H · ∥ K-prep |
| **K** — Runner `verify` + `review-export` + corrections + glossary | T16 | `a` | **yes** | — | J, D, E |
| **L** — Runner `report --coverage` + `reconcile` + calibration print | T17, T18 (gate) | `a` | **yes**, stops at HG-4 | — | J, H · ends at **HG-4** |
| **M** — SK corpus loop to the coverage bars | T19 | `b` `[HUMAN in loop]` | no | HG-4 | F, I, K, L |
| **N** — CS corpus loop + CS spot-check gate | T20 | `b` `[HUMAN in loop]` | no | HG-4 | M (tooling), E (cs bar) |
| **O** — Language visibility backend, **soft-failing** | T21 | `c` | no | — | — · ∥ everything |
| **P** — iOS picker gating | T22 (client code) | `a` | **yes** | O deployed | O |
| **Q** — Validator hardening (soft → 422) | T26 | `c` `[HUMAN gate]` | no | **HG-6** | P + founder-requested TF build installed |
| **R** — Cutover: gate on + DD16 `/start` fix | T23 | `c` `[HUMAN gate]` | no | **HG-5** | M, L exits 0 |
| **S** — Serve-path deletion (the big sweep) | T24 | `c` | no | **HG-7** | R live + verified |
| **T** — Cache retirement + `EXPLAIN ANALYZE` | T25 | `c` | no | — | S deployed + verified |

**Critical path:** HP-1 → A → B/HG-2 → F, and independently G/HG-3 → H → I → J → K/L → HG-4 → M → HG-5 → R → HG-7 → S → T. Stage 6 (O → P → HG-6 → Q) runs beside all of it.

---

## Human prerequisites & founder gates

**HP-1 — DeepL API key (blocks Session A's DeepL arm; nothing else).** Company account per repo convention.

1. Open <https://www.deepl.com/pro-api> in a browser and choose **DeepL API Free** (500 000 characters/month — ample for the arm test).
2. Sign up with the **company** account (not a personal address). DeepL asks for a credit card even on the free tier for identity verification; it is not charged on the Free plan.
3. After sign-up open **Account → API keys** (deepl.com/account/summary) and copy the **Authentication Key for DeepL API** (a string ending in `:fx` on the Free plan — the `:fx` suffix is part of the key, keep it).
4. Paste it into `apps/quiz-pack-api/.env` as a new line: `DEEPL_API_KEY=<the key including :fx>`. That file is gitignored — never commit the key, never put it in `~/.zshrc`.
5. No Fly secret is needed: DeepL is only ever called by the offline arm script, never by a deployed service.
6. Tell the agent "DeepL key is in `.env`" — Session A verifies it by translating one short string.

**Founder gates** (each one is a stop point; the agent must not proceed past it on its own):

| Gate | Where | What the founder does |
|---|---|---|
| **HG-2** | end of Session B | Rates the blind arm batch on the #154 rating web → **model-per-language verdict** (`sk=…`, `cs=…`), recorded verbatim in the parent plan. |
| **HG-3** | inside Session G | Approves applying the additive migration to the **prod** logical DB after staging is green. |
| **HG-4** | end of Session L | Reviews the first 18-cell eligible-EN crosstab and **confirms or adjusts** the 10 / 95 % / 30 constants before any bar gates a cutover (T18). |
| **HG-5** | before Session R | Explicit go for the SK cutover — the first change to what prod serves. Precondition: `report --coverage --language sk` exits 0 or carries recorded waivers. |
| **HG-6** | before Session Q | Confirms the T22 TestFlight build is **installed on their device**. (TF builds are requested by the founder only — no session triggers one.) |
| **HG-7** | between R and S | Confirms one SK session end-to-end + an EN smoke in prod, no drift reports in Sentry. |
| CS spot-check | inside Session N | Spot-checks 20 randomly sampled CS approvals; any `critical` re-opens the judge. |

---

## Ready prompt — Session A (Arm tooling)

```
Work on issue #168, Session A only: the batch adapter + the arm-test translation script (tasks T1 code half, T2, T3). Do NOT touch the DB, the retriever, the serializers or anything in apps/quiz-agent — Stage 3+ owns those. Precondition: DEEPL_API_KEY is in apps/quiz-pack-api/.env (HP-1).

Read first (already mapped — do not re-map the repo):
- docs/issues/issue-168-execution-prompts.md → "Recon snapshot" + "Locked decisions" (esp. DD7, DD8, DD9).
- docs/issues/issue-168-batch-translation-pipeline-sk-cs.md → DD7, DD8, DD9, T1–T3.
- packages/shared/quiz_shared/llm/factory.py → gateway():263-270, _REMAP_OPENROUTER:168-196, resolve_model:273-285, native anthropic client :320-345. There is NO batch surface today.
- apps/quiz-pack-api/scripts/source_facts.py:23-88 → the script idiom (usage docstring, sys.path.insert, argparse, fail-loud gate).
- apps/quiz-pack-api/scripts/rating_page/publish_batch.py:42-65 → the exact JSON shape each arm file must emit.

Build:
1) Add `deepl` to apps/quiz-pack-api/pyproject.toml dependencies (T1 code half; the key itself is already provisioned).
2) packages/shared/quiz_shared/llm/batch.py — a thin submit/poll/retrieve adapter, no framework, typed job id + status. STEP 0 FIRST: a 5-request OpenRouter batch smoke. If OpenRouter batch does not behave as documented, fall back to native Anthropic Message Batches via the existing anthropic.AsyncAnthropic client (factory.py:320-345). Do not build anything on an unproven route.
   Then record the outcome in docs/issues/issue-168-batch-translation-pipeline-sk-cs.md as a line starting exactly "Batch-route verdict:" naming the chosen route and what the smoke showed (acceptance greps for it; "TBD" fails).
3) apps/quiz-pack-api/scripts/translate_arms.py — 4 arms (opus / gemini-2.5-pro / gpt-4.1 / deepl) x ~35 questions x sk AND cs. Sample the questions deterministically (--seed) from prod: eligible = pack_id IS NULL AND review_status='approved' AND language_dependent=false, spread across the 6 categories and 3 difficulties; reach prod read-only through `fly proxy` (DATABASE_URL is a Fly secret). Three arms go through the batch adapter; the DeepL arm calls the deepl SDK synchronously and skips the batch path entirely. Output: one JSON list per (arm, language) in the publish_batch.py:42-65 shape, under data/translation_arms/.
Run it for real and leave the arm files on disk for Session B.

Done = `uv run --no-sync python scripts/translate_arms.py --help` works from apps/quiz-pack-api/; 8 arm files exist (4 arms x 2 languages) each with ~35 items; unit tests for the batch adapter green (`cd apps/quiz-pack-api && pytest tests/ -v`); `uvx ruff check` clean; the "Batch-route verdict:" line is in the issue file.
Git: branch feat/168-arm-tooling, conventional commits, open a PR (`gh pr create`), address the Claude Code Review findings, squash-merge when green. Tick T1/T2/T3 in the issue file and update the #168 line in docs/todo/TODO.md.
```

---

## Ready prompt — Session B (Arm publish + founder verdict) — `[HUMAN]`, not loop-eligible

```
Work on issue #168, Session B only: publish the Session A arm files as one blind rating batch and capture the founder's model-per-language verdict (task T4). Write no new pipeline code.

Read first: docs/issues/issue-168-execution-prompts.md ("Recon snapshot" → ratings), apps/quiz-pack-api/scripts/rating_page/publish_batch.py:42-65,85, apps/quiz-pack-api/app/api/v1/ratings.py:53,84,118,197, docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD8.

Do:
1) Publish ONE blind batch per language from the Session A files:
   uv run --no-sync python scripts/rating_page/publish_batch.py --arm opus=data/translation_arms/opus-sk.json --arm gemini=… --arm gpt41=… --arm deepl=… --seed <N> --title "#168 translation arms SK" --base-url <prod rating web> --rater founder
   (cwd apps/quiz-pack-api; ADMIN_API_KEY from .env — batch-create is X-Admin-Key protected, the rating page itself is not.) Repeat with the CS files.
2) Blinding is structural — never print the arm mapping anywhere the founder can see it, and never pass an `arm` field into the rater-visible payload (ratings_schemas.py:29-42 uses extra="forbid" and will 422).
3) Hand the founder the two rating URLs in chat, plus a one-line reminder that translation defects go in the free-form flags field (Rating.extra["flags"] — no migration needed).
4) STOP. This is founder gate HG-2. Do not start Session F or any corpus work while it is open.
5) When the verdict comes back, export the ratings (`ratings export`, X-Admin-Key), unblind, and record in docs/issues/issue-168-batch-translation-pipeline-sk-cs.md a line starting exactly "Model-per-language verdict:" naming the winning model for sk and for cs plus the score summary that justified it. Standing rule: no model change without eval data + founder approval.

Done = both batches published, the verdict line present in the issue file (not "TBD"), acceptance grep `grep -A1 'Batch-route verdict\|Model-per-language verdict' docs/issues/issue-168-batch-translation-pipeline-sk-cs.md` returns real decision lines.
Git: branch docs/168-arm-verdict, PR, squash-merge. Tick T4.
```

---

## Ready prompt — Session C (Translation-defect reference sets)

```
Work on issue #168, Session C only: build the two translation-defect reference sets (task T5). Write no verification code — Sessions D/E consume these files.

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD6 + DD10 + recon §5; docs/issues/issue-168-execution-prompts.md ("Recon snapshot" → eval harness); apps/quiz-pack-api/scripts/factcheck_eval_166.py:48,52,90,367-401 (the harness shape — NOT its qids); docs/issues/issue-128-idiom-questions-break-in-translation.md and issue-126-answer-trailing-punctuation-false-negative.md (real historical defects).

Build docs/testing/translation-defect-reference-sk.json (~20 items) and docs/testing/translation-defect-reference-cs.json (~12 items). Each item: {qid, language, source, target, defect_category, severity}. Composition per DD6:
1) REAL mined defects — pull the retiring SQLite cache from prod read-only (`fly ssh sftp get /data/translations.db` from quiz-agent-api, into a scratch dir, never into git) and mine it, plus the repo docs above, for genuine SK defects: the Grešníci calque, the murder-of-crows idiom, zázvorové mačky calques, the trailing-punctuation answer case.
2) SYNTHETIC injections — the 5 classes: answer-flip, unit change, untranslated string, title mistranslation, register calque.
3) ~1/3 clean controls (correct translations that must NOT be flagged).
CS is thinner by construction: the 5 synthetic classes reproduce mechanically, mined real CS defects exist only for whatever CS rows the cache actually holds. If the cache holds none, say so explicitly in the file's header comment and in your report — do not pad the set to hit a count.
FAIL LOUD: if the SQLite pull fails (fly auth, missing volume), stop and report. Do not silently ship a synthetic-only SK set — DD6's SK bar assumes mined real defects.
Never reuse the #166 qids (q03,q32,q48,q63,q81,q89,q95) — those are factual errors in English and would certify nothing.

Done = both JSON files exist, schema-valid, severity distribution and mined-vs-synthetic counts printed in the PR body; `uvx ruff check` clean (no code, but keep any helper script lint-clean).
Git: branch feat/168-defect-reference-sets, PR, squash-merge. Tick T5.
```

---

## Ready prompt — Session D (Guards + delta answerability)

```
Work on issue #168, Session D only: the deterministic guards and the delta answerability check (tasks T6, T7) in the new package apps/quiz-pack-api/app/translation_verification/. Do NOT write the MQM judge or regional classifier (Session E) and do NOT wire anything into the orchestrator — DD12 says these are pure functions called only by the runner.

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD12 + DD13 + recon §9; apps/quiz-pack-api/app/verification/answerability.py (AnswerabilityChecker:101, check():138, _PROMPT:36-41, _mcq_answers_match:85, _text_answers_match:67, _normalize:51-56, _ARTICLES:34, fail-safe :151-155, open-shape skip :175-178); apps/quiz-pack-api/app/scoring/craft_guards.py:66,74,81 (regexes only); packages/shared/quiz_shared/llm/factory.py:160 (ANSWERABILITY role = deepseek-v4-flash).

Build:
1) translation_verification/guards.py — 6 deterministic guards over (source_question, translated_draft, language), no LLM: number/date preservation · unit preservation (reuse craft_guards._IMPERIAL_ALWAYS_RE:66 / _METRIC_RE:81 as EXTRACTION helpers only) · untranslated-string detection (target ≈ source for a language_dependent=false item) · MCQ shape (same option keys, same count, no duplicate option texts, correct_answer_key still resolvable) · placeholder/markup integrity · length ratio. Each returns a reason string like the craft guards, but these run ALWAYS ENFORCING — CRAFT_GUARDS_ENFORCE has no say here (they check invariants, not taste).
2) translation_verification/answerability.py — the DD13 delta check wrapping the existing AnswerabilityChecker: control leg on the EN source and treatment leg on the translated draft, identical settings, IN THE SAME batch submission. Verdicts: en_pass ∧ ¬tgt_pass → translation_flip (critical, blocks approval) · ¬en_pass → control_fail (never blames the translation, logged for a corpus follow-up) · both pass or both fail → pass · either leg check_unavailable → unavailable, row stays pending (for a gate the fail-safe direction INVERTS — never approve on a missing judgment). Prompt = _PROMPT:36-41 verbatim in structure with localized instruction text and the answer required in the target language. Comparison: MCQ compares the resolved option key; free text needs a NEW Unicode-safe normalizer (casefold + NFKD accent-aware) because _normalize:51-56 deletes SK/CS diacritics, and _ARTICLES drops out for sk/cs. Return both legs so they can be persisted as {model, en:{…}, target:{…}, verdict, checked_at}.

Done = `cd apps/quiz-pack-api && pytest tests/verification/test_translation_guards.py tests/verification/test_translation_answerability.py -v` green, with each of the 6 guards having a passing AND a failing case, a test that guards enforce regardless of CRAFT_GUARDS_ENFORCE, and the three named DD13 tests: ::test_en_pass_target_fail_blocks_approval, ::test_control_fail_does_not_blame_translation, ::test_unavailable_leaves_row_pending. Full quiz-pack-api suite green, `uvx ruff check` clean.
Git: branch feat/168-translation-guards-answerability, PR, squash-merge. Tick T6/T7.
```

---

## Ready prompt — Session E (MQM judge + regional flag + judge validation)

```
Work on issue #168, Session E only: the MQM-Quiz judge, the regional-relevance flag, and the eval harness that validates them against the DD6 bars (tasks T8, T9). Session C (reference sets) must be merged. Do not touch guards/answerability (Session D) or the runner (Session J/K).

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD6 + DD12 + recon §5/§9; apps/quiz-pack-api/app/verification/fact_verifier.py:69-83 (VerificationResult) and :337-345 (_held — fail-CLOSED, adopt this contract, not the fact-check prompt); app/verification/shape_classifier.py:45 (single-attribute classifier shape); apps/quiz-pack-api/scripts/factcheck_eval_166.py:90 (done_qids JSONL resume) and :367-401 (cmd_report scorer) and :405-420 (subcommand layout); docs/testing/translation-defect-reference-sk.json + -cs.json.

Build:
1) app/translation_verification/judge.py — the MQM-Quiz judge over (source_question, translated_draft, language): calques, idioms, naturalness/register, titles and proper nouns. Severity taxonomy critical/major/minor; CRITICAL BLOCKS approval. Adopt the fail-closed VerificationResult contract so an unavailable judge leaves the row `pending`, never approved. Per-language glossary input (sk.json/cs.json — a reviewed git file, empty for now, curated later in Session K; never auto-derived).
2) app/translation_verification/regional.py — a single-attribute classifier in the ShapeClassifier shape returning (flag, reason). FLAG ONLY: it must never block or drop a row (locked decision 3(d)).
3) apps/quiz-pack-api/scripts/translation_judge_eval.py — a sibling of factcheck_eval_166.py reusing its JSONL-resume and cmd_report scorer shape with ITS OWN items (the DD6 sets), subcommands judge|report, --language sk|cs.
Then RUN it for both languages and iterate the judge prompt until the bar is met.

Done = `uv run --no-sync python scripts/translation_judge_eval.py report --language sk` (cwd apps/quiz-pack-api) exits 0 with EVERY critical defect caught and ZERO critical false positives on the controls; the same for --language cs; major/minor recall printed and explicitly non-gating. Plus `pytest tests/verification/test_translation_regional.py -v` green with ::test_regional_flag_never_blocks_approval and ::test_regional_flag_and_reason_persisted_in_verification_json. `uvx ruff check` clean.
If a bar cannot be met after honest prompt iteration, STOP and report the measurements — do not weaken the bar.
Git: branch feat/168-mqm-judge, PR, squash-merge. Tick T8/T9.
```

---

## Ready prompt — Session F (Answerability competence pre-check)

```
Work on issue #168, Session F only: the DD13 competence pre-check (task T10). Sessions B (founder verdict) and D (delta answerability) must be merged. Write no new components — this session measures.

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD13 (esp. "Model class" and "Ordering — DD13 depends on DD8's output"); apps/quiz-pack-api/app/translation_verification/answerability.py (Session D); packages/shared/quiz_shared/llm/factory.py:160.

Do:
1) Take the ~20 founder-APPROVED items per language from the winning arm (Session B's rated batch — the winning arm's output only). If a language yields fewer than ~20 approved items, do NOT run on a thin sample: say so and defer that language's pre-check to the first verified corpus batch (DD13 says exactly this).
2) Run the delta check over those known-good translations with the current answerability role model (deepseek-v4-flash) and measure the FLIP RATE — how often a human-approved translation is called translation_flip.
3) Record the measurement per language in docs/issues/issue-168-batch-translation-pipeline-sk-cs.md (model, n, flip rate, date).
4) If the flip rate exceeds 10 % for a language, the role model is unusable there: STOP and escalate to the founder in chat with the measurement, proposing a frontier model. Never swap the model yourself — standing rule: no model change without eval data + approval.

Done = flip rate recorded per language and either ≤ 10 %, or a founder-approved alternative model named in the issue file with the measurement that justified it (acceptance criterion "DD13 competence pre-check output recorded per language").
Git: branch docs/168-answerability-competence, PR, squash-merge. Tick T10.
```

---

## Ready prompt — Session G (Migration + models) — `[HUMAN gate HG-3]`, not loop-eligible

```
Work on issue #168, Session G only: the additive Postgres migration and its SQLAlchemy models (task T11). This is class b/c — it touches BOTH logical DBs on the shared quiz-pack-db cluster. Do NOT declare approved_languages in packages/shared/quiz_shared/database/pgvector_client.py in this session — that is T12/Session H, and it may only land after BOTH databases have the column (a shared table declaring a missing column 500s every retrieval, EN included).

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD3 + DD4 ("Migrate before deploy") + T11; docs/issues/issue-168-execution-prompts.md ("Recon snapshot" → quiz-pack-api + Envs); apps/quiz-pack-api/alembic/versions/f2a91c4b8e57_order_generation_mode.py (head; re-verify with `alembic heads` before writing) and a7fa4d9d6751_ratings_store.py (table-creation idiom); apps/quiz-pack-api/app/db/models/question.py:75,120,129,157 and rating.py:48,68 (model style); docs/issues/issue-101-prod-sandbox-environment-separation.md:29 (two logical DBs, separate version tables).

Build (one migration on the quiz-pack-api chain, down_revision = the verified head):
1) question_translations — question_id FK → questions.id ON DELETE CASCADE, language, UNIQUE(question_id, language), status (pending/approved/rejected/stale), payload columns (question, possible_answers JSONB, explanation, headline_answer, correct_answer, correct_answer_key, alternative_answers JSONB), provenance (model, prompt_version, batch_id, cost_cents NULLABLE, source_hash NOT NULL on new rows), verification JSONB, timestamps.
2) question_translation_corrections — append-only: translation_id, field, before, after, category (MQM-Quiz), note, source, created_at.
3) questions.approved_languages TEXT[] NOT NULL DEFAULT '{}' + a GIN index.
4) Matching SQLAlchemy models in apps/quiz-pack-api/app/db/models/.
Then, in order — this order is the safety mechanism:
  a) `alembic upgrade head` against quiz_pack_staging (via `fly proxy`, run alembic from the REPO ROOT), verify `\d+ questions` shows the column + GIN index and `SELECT count(*) FROM question_translations` succeeds, and confirm an up/down/up round-trip on a scratch DB.
  b) STOP — founder gate HG-3. Report to the founder in chat: what the migration adds, that it is additive with a DEFAULT so the currently deployed code keeps running unchanged, and that staging is green. Ask for the go.
  c) Only after the go: apply to the prod logical DB the same way.

Done = migration applied cleanly to quiz_pack_staging AND the prod logical DB; `pytest apps/quiz-pack-api/tests/test_alembic_autogenerate_guard.py apps/quiz-agent/tests/test_alembic_migration_drift.py` green (no model/schema drift); the `\d+ questions` output recorded in the PR body.
Git: branch feat/168-translation-schema, PR, squash-merge. Tick T11. Note in the issue file that both DBs are migrated — Session H depends on that fact.
```

---

## Ready prompt — Session H (Shared store: `$contains`, fail-loud, `get_translations`, staleness)

```
Work on issue #168, Session H only: the shared-store changes (tasks T12, T13). PRECONDITION: Session G merged and the migration applied to BOTH the prod and quiz_pack_staging logical DBs — verify that first (`\d+ questions` shows approved_languages) and stop if it is not true. The gate stays INERT in this session: no filter key is emitted anywhere and nothing writes approved_languages.

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD1, DD2, DD3 (source_hash definition + "Who notices an edit"), DD5, T12, T13; packages/shared/quiz_shared/database/pgvector_client.py:74-107 (questions_table), :113-134 (_build_where, silently skips unknown keys at :118-122), :167 (add, ON CONFLICT DO NOTHING), :185 (upsert), :238-244 (count), :270-290 (search); apps/quiz-agent/app/api/admin.py:331,375,425 (the admin writers that reach upsert) and :267 (import → add, cannot edit).

Build:
1) questions_table gains approved_languages (TEXT[]).
2) _build_where gains a `$contains` operator compiling to Postgres `@>` AND raises ValueError on any key absent from questions_table.c (today a typo is skipped silently — for a gate that means serving everything). Verify no live caller relies on the old best-effort contract: quiz-pack-api's generation/storage.py filters are applied in Python and never reach this store.
3) New store method get_translations(question_ids, language) → the approved rows, one indexed lookup, batched over ids.
4) source_hash per DD3 exactly: sha256 over json.dumps({question, possible_answers, correct_answer, alternative_answers, explanation}, sort_keys=True, ensure_ascii=False, separators=(",", ":")), None → "", nested dicts key-sorted, every string strip()ed and NFC-normalized. Computed at ingest; and INLINE DEMOTION in upsert: if the recomputed hash differs from a stored approved row's, the SAME transaction sets that row status='stale' and removes the language from that question's approved_languages.

Done = `cd apps/quiz-pack-api && pytest tests/db/test_pgvector_client.py -v` green including ::test_build_where_unknown_key_raises and ::test_build_where_contains_emits_array_contains; `pytest tests/db/test_translation_staleness.py::test_upsert_source_edit_demotes_translation` green; both full suites (`apps/quiz-agent`, `apps/quiz-pack-api`) green — EN behaviour must be untouched; `uvx ruff check` clean.
Do NOT deploy — Session I owns that.
Git: branch feat/168-store-language-gate, PR, squash-merge. Tick T12/T13.
```

---

## Ready prompt — Session I (Inert prod deploy) — class `c`, not loop-eligible

```
Work on issue #168, Session I only: deploy the gate-inert code to prod (task T14). Session H merged; the schema is already live on both logical DBs from Session G, so there is no un-deployable window.

Read first: .claude/rules/backend.md (deploy pointers), docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD4 ("Migrate before deploy") + DD11 + T14.

Do:
1) Confirm nothing emits the gate key and nothing writes approved_languages yet (grep for approved_languages in apps/quiz-agent/app — it must appear only in the shared table declaration path, never in _build_metadata_filters).
2) Deploy quiz-pack-api and quiz-agent-api from the repo root (`/deploy` or the documented fly deploy commands).
3) Post-deploy verification: EN smoke on prod — POST /quiz/start + 3 questions answered, plus an existing SK session still behaving exactly as before (the serve-time translator is still live at this point). Check Sentry for new errors for 10 minutes.

Done = both apps healthy on prod, EN smoke green, no new Sentry issues, and the deployed image ids recorded in the issue file. Rollback = re-deploy the previous image (the migration stays — it is additive).
Git: no code change expected; if a deploy fix is needed, branch fix/168-inert-deploy, PR, squash-merge. Tick T14.
```

---

## Ready prompt — Session J (Runner core: plan / submit / poll / ingest)

```
Work on issue #168, Session J only: the batch translation runner's core subcommands (task T15). Sessions G+H merged. Do NOT build verify/review-export (Session K) or report/reconcile (Session L) — leave them unimplemented stubs that exit non-zero with "not implemented yet".

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD7 + DD9 + DD3 (the row shape) + T15; apps/quiz-pack-api/scripts/source_facts.py:23-88 (script idiom, run with `uv run --no-sync python scripts/… ` from apps/quiz-pack-api/); apps/quiz-pack-api/scripts/factcheck_eval_166.py:90 (done_qids resume); packages/shared/quiz_shared/llm/batch.py (Session A adapter); apps/quiz-pack-api/app/cost_tracking.py:75-99 (fetch_openrouter_usage — returns None, never a fake 0); the question_translations model from Session G.

Build apps/quiz-pack-api/scripts/translate_corpus.py with plan | submit | poll | ingest:
- `plan` is the DEFAULT and is free: prints the work set (eligible untranslated/stale rows for --language) and a cost estimate. `submit` requires an explicit flag AND --limit. Expensive steps are never the default (standing rule).
- Durable progress: one JSONL per job at data/translation_jobs/<job_id>.jsonl; resume via the done_qids pattern.
- The DB row is written ONLY at `ingest` — a crashed job must never leave half-approved content. Ingest writes status='pending' rows with the full payload INCLUDING translated alternative_answers, provenance (model, prompt_version, batch_id, source_hash computed from the source row it was produced from) — and never touches approved_languages (that flips only at approval, Session K).
- Cost per DD9: record per-batch spend in the job JSONL (OpenRouter /credits delta; DeepL by character count x rate) and persist the per-question share to question_translations.cost_cents. An unavailable usage read stores None, NEVER a fake 0.
- Partial batch failures exit non-zero with the failed ids listed. Never silently approve.

Done = `pytest apps/quiz-pack-api/tests/scripts/test_translate_corpus_cost.py::test_batch_cost_is_persisted_per_question_to_cost_cents` green; a `plan --language sk` run against staging prints a sane work set and estimate; a `submit --limit 3 --confirm` + poll + ingest round-trip writes 3 pending rows with source_hash set; resume after a kill re-enters without duplicating; `uvx ruff check` clean.
Git: branch feat/168-translate-corpus-runner, PR, squash-merge. Tick T15.
```

---

## Ready prompt — Session K (Runner verify + review loop)

```
Work on issue #168, Session K only: the runner's verify and review-export subcommands plus correction ingest and the glossary histogram (task T16). Sessions D, E and J merged.

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD3 (corrections table + glossary rule), DD12, DD13, T16; apps/quiz-pack-api/app/translation_verification/{guards,answerability,judge,regional}.py (Sessions D+E); scripts/translate_corpus.py (Session J); scripts/rating_page/publish_batch.py:42-65 (export payload shape); app/api/v1/ratings_schemas.py:26 (Rating.extra["flags"]).

Build, inside translate_corpus.py:
1) `verify` (explicit flag + --limit required): chains guards → delta answerability → MQM judge → regional flag over pending rows, writing the whole outcome into question_translations.verification JSONB (both answerability legs stored per DD13). Approval rules: any guard failure or a critical judge finding or a translation_flip BLOCKS; any unavailable leg leaves the row `pending` (fail-closed); a regional flag NEVER blocks. When a row is approved, add the language to questions.approved_languages IN THE SAME TRANSACTION (that column is a derived index of this table — the two must never disagree).
2) `review-export`: selects critical + flagged + a random sample and emits the publish_batch.py:42-65 shape for the #154 rating web.
3) Correction ingest: writes append-only rows into question_translation_corrections (translation_id, field, before, after, MQM category, note, source). Never edit in place — the category histogram is the glossary loop's input and in-place edits erase it.
4) Glossary: print the category histogram; the glossary files sk.json/cs.json are REVIEWED GIT ARTEFACTS and must never be auto-written.

Done = `pytest apps/quiz-pack-api/tests/scripts/test_translate_corpus_review.py -v` green with ::test_review_export_selects_critical_flagged_and_random_sample, ::test_correction_ingest_appends_row_with_mqm_category, ::test_glossary_histogram_is_report_only; a verify run over a handful of staging rows produces the expected verification JSONB and flips approved_languages only for approved rows; `uvx ruff check` clean.
Git: branch feat/168-runner-verify-review, PR, squash-merge. Tick T16.
```

---

## Ready prompt — Session L (Coverage report + reconcile + calibration) — ends at founder gate HG-4

```
Work on issue #168, Session L: the runner's report --coverage and reconcile subcommands (task T17), then the calibration hand-off to the founder (task T18 = gate HG-4). Sessions H and J merged.

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD4 (the whole "step-4 gate" + remedy + "numbers are defaults" paragraphs), DD1 (drift control, both reconcile legs), DD3 (source_hash), T17, T18; apps/quiz-agent/app/retrieval/question_retriever.py:251-267 (why the cell is category x difficulty) and :368-376 (why the category floor exists); apps/quiz-agent/app/api/admin.py:154-161 (CATEGORY_TAXONOMY, 6 values).

Build, inside translate_corpus.py:
1) `report --coverage --language <lang>` — counts SERVING-ELIGIBLE rows (pack_id IS NULL AND review_status='approved' AND language_dependent=false) per cell across 6 categories x 3 difficulties = 18 cells, for EN and for the target (approved_languages @> {lang}). Three bars, all required: cell ratio ≥ 95 % of the cell's EN count (cells with EN < 10 are reported en_starved and excluded from bars 1–2) · cell floor ≥ 10 translated rows · category floor ≥ min(30, ceil(0.95 x eligible EN rows)) with the thin-category escape reported as en_starved_category. On failure: exit non-zero listing every failing cell (category, difficulty, en, translated, ratio) AND the qids of untranslated eligible EN rows (that list is directly the next `submit --limit` work set). `--waive <category>[/<difficulty>]="<reason>"` prints WAIVED, records bar/cell/reason/date verbatim in the run-report JSON, exits 0 — per run only, never persisted as config. Prod's approved-only population is binding; the TestFlight channel set is reported alongside but never relaxes a bar. The 10 / 95 % / 30 values are NAMED CONSTANTS overridable by CLI flags.
2) `reconcile --language <lang>` — two legs, both exiting non-zero on a finding: consistency (recompute approved_languages from question_translations, report any mismatch) and staleness (recompute each approved row's source_hash from the CURRENT English question; on mismatch demote in one transaction — status='stale', language removed from approved_languages — and report qid, language, old_hash, new_hash).
3) Then run `report --coverage --language sk` against prod (read-only, via fly proxy) to print the FIRST full 18-cell crosstab of eligible EN rows.
4) STOP at founder gate HG-4: present the crosstab in chat and ask the founder to confirm or adjust the 10 / 95 % / 30 constants. Those numbers are derived from the retrieval shape, not from the corpus — say so. No corpus batch (Session M) may start before this confirmation.

Done = `pytest apps/quiz-pack-api/tests/scripts/test_translate_corpus_report.py::test_thin_cell_exits_nonzero_and_lists_cells` and tests/scripts/test_translate_corpus_reconcile.py::test_stale_source_hash_demotes_and_exits_nonzero green; `reconcile --language sk` exits 0 on a consistent DB; the crosstab is recorded in the issue file and the founder's confirmed constants noted beside it.
Git: branch feat/168-coverage-reconcile, PR, squash-merge. Tick T17; tick T18 only after the founder confirms.
```

---

## Ready prompt — Session M (SK corpus loop) — class `b`, `[HUMAN in loop]`, not loop-eligible

```
Work on issue #168, Session M: translate, verify and review the SK corpus until the coverage bars pass (task T19). This session WRITES TRANSLATION ROWS AND approved_languages INTO THE PROD DB — class b, founder in the loop. Preconditions: gate HG-4 done (constants confirmed), Sessions F, I, K, L merged, and the model-per-language verdict for sk recorded (Session B).

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md locked decisions 1/2/5, DD4 (step 3 + the remedy paths), DD7, T19; scripts/translate_corpus.py --help.

Loop, in batches (locked decision 1: incrementally as testers grow, never the whole corpus in one shot):
1) `plan --language sk` → review the work set and the cost estimate with the founder before spending.
2) `submit --language sk --limit N --confirm` → `poll` → `ingest` (pending rows only).
3) `verify --language sk --limit N` → guards + delta answerability + judge + regional. Anything critical/flagged stays pending.
4) `review-export --language sk` → publish to the #154 rating web → founder reviews critical + flagged + the random sample → ingest the corrections (append-only) and, when the category histogram justifies it, propose glossary sk.json edits AS A REVIEWED PR — never auto-write the glossary.
5) `report --coverage --language sk`. If it exits non-zero, take the printed shortfall qids straight back to step 2, or ask the founder for an explicit `--waive` with a verbatim reason. Never lower a constant to make a bar pass.
6) `reconcile --language sk` must exit 0 before you call the language done.

Stop and report to the founder on: any batch failing partially, an unexpected cost jump, a judge/answerability availability outage (rows stay pending — that is correct, not a bug to work around), or a bar that cannot be met without a waiver.

Done = `report --coverage --language sk` exits 0 (waivers, if any, printed as WAIVED with the founder's verbatim reason in the run-report JSON) and `reconcile --language sk` exits 0. Record the final coverage numbers and total cost per approved question in the issue file.
Git: one PR per meaningful batch of code/doc changes; the data lands in prod, not in git. Tick T19 when the bars pass.
```

---

## Ready prompt — Session N (CS corpus loop + CS spot-check gate) — class `b`, `[HUMAN in loop]`, not loop-eligible

```
Work on issue #168, Session N: the same loop as Session M but for cs, plus the DD6 CS-only gate (task T20). Session M's tooling path is proven; the CS judge bar (Session E, --language cs) must already pass.

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD6 ("CS gets its own bar"), DD4 (step 4 is per language), T20; the Session M prompt above (same loop, same stop conditions).

Run the identical batch loop with --language cs, using the cs model from the founder's verdict. Then the CS-only gate, which SK does not have:
- Randomly sample 20 approved CS translations, publish them to the rating web, and ask the founder to spot-check.
- ANY critical defect found there FAILS the bar: re-open the judge (back to Session E's prompt iteration + a new judge_eval run), do not proceed to the CS cutover.
- Record the founder's verdict in docs/issues/issue-168-batch-translation-pipeline-sk-cs.md — the acceptance criterion requires the 20-sample verdict recorded with no unresolved critical.

Done = `report --coverage --language cs` exits 0, `reconcile --language cs` exits 0, and the 20-sample CS spot-check verdict is recorded with no unresolved critical.
Note: SK may cut over (Sessions R–T) while CS is still in this loop — DD4 step 4 is evaluated per language. Tick T20.
```

---

## Ready prompt — Session O (Language visibility backend, soft-failing) — class `c`, not loop-eligible

```
Work on issue #168, Session O only: the servable-language helper, the new endpoint, and SOFT-FAILING validators (task T21) — plus their deploy. Independent of the whole translation pipeline; can run any time. Do NOT harden the validators to 422 for non-servable codes — that is T26/Session Q and it must wait until the gated iOS build is on the founder's device.

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD14 + DD15 + T21 + T26; apps/quiz-agent/app/api/deps.py:60-62 (shape-only ^[a-z]{2}$ validator); apps/quiz-pack-api/app/api/v1/orders.py:89 (_ALLOWED_LANGUAGES) and :176-179 (its enforcement); apps/ios-app/Hangs/Hangs/Models/Language.swift:18-31 (the display catalogue stays all 10).

Build:
1) packages/shared/quiz_shared/languages.py — QUIZ_LANGUAGES (all 10 codes; the data model stays language-agnostic) + servable_quiz_languages() reading SERVABLE_QUIZ_LANGUAGES (default "en,sk,cs") + pack_order_languages() reading PACK_ORDER_LANGUAGES (default "en").
2) GET /api/v1/languages → {"quiz": [...], "pack_order": [...]}.
3) Validators, SOFT: deps.py:60-62 and orders.py:176-179 reject any code outside QUIZ_LANGUAGES with 422 (already stricter than today's ^[a-z]{2}$), but ACCEPT a servable-list miss (de/fr/es/it/pl/hu/ro) with a WARNING log + a Sentry breadcrumb naming the code — every installed build still offers all 10 and must not start 422-ing mid-flight. Replace _ALLOWED_LANGUAGES with the shared helper so the two services cannot drift.
4) Deploy: fly deploy of quiz-agent-api AND quiz-pack-api from the repo root. Safe at any time, no client dependency, no migration.

Done = `pytest apps/quiz-agent/tests/test_language_enforcement.py -v` green with ::test_legacy_language_accepted_with_deprecation_warning (POST /quiz/start {"language":"de"} → 200 + a WARNING naming the code) and ::test_unknown_code_rejected ({"language":"zz"} → 422); `curl -s localhost:8003/api/v1/languages` → {"quiz":["en","sk","cs"],"pack_order":["en"]}; flipping SERVABLE_QUIZ_LANGUAGES=en,sk,cs,pl changes the response with no code change; both apps deployed and healthy.
Git: branch feat/168-servable-languages, PR, squash-merge, then deploy. Tick T21.
```

---

## Ready prompt — Session P (iOS picker gating)

```
Work on issue #168, Session P only: the iOS language-picker gating (task T22). Session O must be deployed (the endpoint must answer). Do NOT trigger a TestFlight build — TF builds happen only when the founder explicitly asks, right before an on-device test.

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD14 (iOS paragraph) + T22 + T26 (why this build is T26's precondition); .claude/rules/ios.md (schemes, build/test commands); apps/ios-app/Hangs/Hangs/Models/Language.swift:18-31,34,39-41; Views/SettingsView.swift:291, Views/HomeView.swift:294, Views/OrderPack/OrderPackFormStep.swift:65.

Build:
1) Keep Language.supportedLanguages as the full 10-code DISPLAY catalogue (names/native names). Add Language.selectableLanguages, filtered by a list fetched once at launch from GET /api/v1/languages, cached in UserDefaults, falling back to a compiled en,sk,cs when offline.
2) The three picker sites read the filtered list; OrderPackFormStep.swift:65 uses the pack_order list, the other two use quiz.
3) A stored preference for a now-hidden language degrades to Language.default (:34) — it must never 422 mid-session.
4) Run `/verify-api` so the new response model matches its iOS Codable struct.

Done = HangsTests green on the sim including LanguagePickerTests::testHiddenStoredLanguageDegradesToDefault; build clean; /verify-api passes; `swiftformat` clean.
Then report to the founder: "T22 is merged; it reaches devices only on the next TestFlight build you request — T26 (validator hardening) waits for you to confirm that build is installed."
Git: branch feat/168-ios-language-picker, PR, squash-merge. Tick T22.
```

---

## Ready prompt — Session Q (Validator hardening) — class `c`, `[HUMAN gate HG-6]`, not loop-eligible

```
Work on issue #168, Session Q only: harden the language validators from soft to strict (task T26). PRECONDITION — verify it explicitly before touching code: the founder has confirmed the T22 build is INSTALLED ON THEIR DEVICE. If that confirmation is not in hand, stop and ask; hardening before the gated client is on the device 422s an installed build mid-session.

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD14 + T21 + T26; the soft-fail branch added in Session O (apps/quiz-agent/app/api/deps.py:60-62, apps/quiz-pack-api/app/api/v1/orders.py:176-179).

Do:
1) Drop the legacy-accept branch: a code outside servable_quiz_languages() now 422s at both sites.
2) Deploy quiz-agent-api and quiz-pack-api from the repo root. Rollback = re-deploy the previous image.

Done = `pytest apps/quiz-agent/tests/test_language_enforcement.py::test_non_servable_language_rejected_after_hardening` green (POST /quiz/start {"language":"de"} → 422), the soft-phase test updated/removed with a note saying which phase it belonged to, both apps deployed and healthy, and a prod smoke confirming en/sk/cs still start sessions.
Git: branch feat/168-harden-language-validators, PR, squash-merge, then deploy. Tick T26.
```

---

## Ready prompt — Session R (Cutover: gate on) — class `c`, `[HUMAN gate HG-5]`, not loop-eligible

```
Work on issue #168, Session R only: turn the language gate ON and fix /start exhaustion accounting (task T23). THIS IS THE FIRST TASK THAT CHANGES WHAT PROD SERVES. Preconditions, both required: `report --coverage --language sk` exits 0 or carries recorded waivers (Session M), and the founder has explicitly said go (HG-5). Do NOT delete the serve-time translation path in this session — that is T24/Session S, and it only starts after this one is verified live.

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md DD1 (incl. the pack-path and index-honesty paragraphs), DD11, DD16 (whole), T23; apps/quiz-agent/app/retrieval/question_retriever.py:208-269 (pack early return :234-241, channel review_status :246-250, normal branch :251-267) and :62-64 (count); apps/quiz-agent/app/api/routes/quiz.py:124-162.

Build:
1) ONE shared filter helper next to _build_metadata_filters, used by BOTH search and count, emitting {review_status: <the session's channel set>, approved_languages: {"$contains": lang}} — the language key added ONLY when session.language != "en". review_status must mirror the session's channel (TestFlight = {$in:[approved,pending_review]}), never a hardcoded "approved".
2) The gate key goes ONLY into the normal branch. The pack branch (:234-241) stays untouched — a paid bundle must never be emptied. The fallback ladder needs no change and the gate must never become relaxable.
3) DD16: /start exhaustion accounting uses the same gated count → a finished SK/CS pool returns 409 with suggestion: reset_history instead of a 500. The honest 500's filter_lines (:146-156) and the empty-DB message (:140-144) gain the language-aware wording.
4) Deploy quiz-agent-api. Then verify in prod: one SK session end-to-end, an EN smoke (/start + 3 questions), and 10 minutes of Sentry.

Done = `pytest apps/quiz-agent/tests/test_quiz_exhaustion_language.py -v` green (::test_start_quiz_sk_exhaustion_returns_409, ::test_start_quiz_en_count_filter_unchanged); `pytest apps/quiz-agent/tests/db/test_pgvector_store.py::test_sk_session_filter_excludes_untranslated_question` green; `pytest apps/quiz-agent/tests/test_language_gate_filters.py::test_en_metadata_filter_dict_unchanged` green; `pytest apps/quiz-agent/tests/test_retrieval_drift_skip.py::test_pack_branch_exempt_from_language_gate_and_drift_skip` green; deployed and prod-verified.
Then hand gate HG-7 to the founder: their SK session end-to-end + EN smoke, no drift reports in Sentry — that confirmation is Session S's precondition.
Git: branch feat/168-language-gate-on, PR, squash-merge, then deploy. Tick T23.
```

---

## Ready prompt — Session S (Serve-path deletion) — class `c`, gate HG-7, not loop-eligible

```
Work on issue #168, Session S only: delete the serve-time translation path and source everything from the approved row (task T24). This is irreversible on the hot path once deployed. PRECONDITION: Session R is live and the founder has verified it in prod (one SK session end-to-end + an EN smoke, no drift reports in Sentry — gate HG-7). Do NOT touch the SQLite cache env vars or the /data mount — that is T25/Session T.

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md T24 IN FULL (it enumerates the exact blast radius: 29 app occurrences across 6 files, 56 across 19 test files, with the per-file disposition) + DD5 + DD15; apps/quiz-agent/app/serializers.py:98,109,128,192-213,219,235,244; app/quiz/flow.py:112,120,266-271,279,492-493,499-521; app/retrieval/question_retriever.py:110-136 (the two expired-filter points :119 and :129); app/api/deps.py:458 (get_question_store already exists) and :462-463; app/evaluation/evaluator.py:79,92,167-169.

Build (follow T24's dispositions literally — they were measured, not estimated):
1) serializers.py:128 reads the approved row via get_translations instead of translate_question_payload; translated_question_view (:192-213) gains one line copying record["alternative_answers"] so grading uses SK alternates, not English ones.
2) Delete flow.py:509-521 _translate_correct_answer and translate_feedback; the :492-493 branch becomes the only non-EN answer path.
3) Drift skip = ONE shared async helper _drop_untranslated(candidates, session) — batched get_translations, one Sentry report per dropped id, non-EN only — applied at BOTH question_retriever.py:119 (primary) and :129 (fallback output). An emptied primary must still descend the ladder; an emptied fallback must reach _handle_no_candidates. Pack rows never reach the helper (early return :234-241).
4) DI: the translation_service parameter is REPLACED, not deleted — the three serializer helpers take question_store=None; the four route handlers (quiz.py:58,273, tts.py:67,190) swap Depends(get_translation_service) for the existing Depends(get_question_store); QuizFlowService.__init__ (flow.py:112) takes question_store and passes it at :279; main.py drops the TranslationService global/construction/app.state entry and wires the question_store local it already builds (:338); deps.py:462-463 is deleted.
5) Tests per T24: RETIRE test_translation_cache.py, test_translation_fallback.py, test_translation_validation.py, test_feedback_translation_validation.py. PORT test_question_payload_translation.py and test_language_dependent_serving_guard.py (record source changes, asserted values do NOT). The 13 collateral files (16 sites) get a mechanical rename to question_store= plus the one DI override in test_session_route_authorization.py:180 — their assertions must stay identical to main.
6) Deploy quiz-agent-api, then verify in prod: SK session end-to-end + EN smoke + Sentry.

Done = `grep -rn "translate_question_payload\|translate_feedback\|_translate_correct_answer\|translation_service\|TranslationService" apps/quiz-agent/app apps/quiz-agent/tests` exits 1; `pytest apps/quiz-agent/tests -q` green; the named tests green: test_retrieval_drift_skip.py (all four cases incl. the fallback-path and ladder-preservation ones), test_question_payload_translation.py::test_sk_session_grades_against_translated_alternates, and the three unchanged EN assertions listed in the acceptance block.
Git: branch feat/168-delete-serve-time-translation, commits per logical step (serializer+view, flow, drift helper, DI sweep, test dispositions), PR, squash-merge, then deploy. Tick T24.
```

---

## Ready prompt — Session T (Cache retirement + index honesty) — class `c`, not loop-eligible

```
Work on issue #168, Session T only: retire the SQLite translation cache and record the DD1 index-honesty check (task T25). Precondition: Session S deployed and verified in prod.

Read first: docs/issues/issue-168-batch-translation-pipeline-sk-cs.md T25 IN FULL + DD1 ("Index honesty") + DD10; apps/quiz-agent/fly.toml:26,54-56 and fly.staging.toml:27,55-57; apps/quiz-agent/app/translation/__init__.py (it also re-exports get_feedback_message, still used by app/api/routes/tts.py:211-213); app/main.py:71.

Do:
1) Remove TRANSLATION_CACHE_URL (fly.toml:26, fly.staging.toml:27) and TRANSLATION_PROMPT_VERSION, and delete the now-unreferenced TranslationService / TranslationStore modules. EDIT app/translation/__init__.py — do NOT drop the directory: get_feedback_message must keep working for tts.py. main.py:71 also imports TranslationService.
2) ⚠️ The /data mount STAYS (fly.toml:54-56, fly.staging.toml:55-57). It is one shared volume that also backs RATINGS_DATABASE_URL=/data/ratings.db and TTS_CACHE_DIR=/data/tts_cache — removing it destroys unrelated prod state.
3) Optional, only once Session C has mined it: delete the file itself per app, `fly ssh console -C "rm /data/translations.db"` — the FILE only, never the volume.
4) Run EXPLAIN ANALYZE for a real SK-filtered search() against prod and record the plan in the issue file. It should show a SEQUENTIAL scan at the current corpus scale (which is what makes the pre-filter exact); if the planner has started choosing ix_questions_embedding_ivfflat, say so loudly — the filter is then applied after approximate candidate selection and DD1's recall caveat has become live.
5) Deploy both apps; EN + SK smoke; Sentry check.

Done = `grep -rn "TRANSLATION_CACHE_URL\|TRANSLATION_PROMPT_VERSION" apps packages --include=*.py --include=*.toml` exits 1; `grep -c 'destination = "/data"' apps/quiz-agent/fly.toml apps/quiz-agent/fly.staging.toml` still returns 1 for each with RATINGS_DATABASE_URL + TTS_CACHE_DIR untouched; full quiz-agent suite green; the EXPLAIN ANALYZE plan recorded in the issue file.
Git: branch chore/168-retire-translation-cache, PR, squash-merge, then deploy. Tick T25 and close the issue's acceptance checklist.
```

---

## Status

- ⬜ **HP-1** DeepL account + API key (founder)
- ⬜ **A** Arm tooling (T1 code, T2, T3) · ⬜ **B** Arm publish + verdict (T4) → **HG-2**
- ⬜ **C** Defect reference sets (T5) · ⬜ **D** Guards + delta answerability (T6, T7) · ⬜ **E** Judge + regional + judge eval (T8, T9) · ⬜ **F** Competence pre-check (T10)
- ⬜ **G** Migration (T11) → **HG-3** · ⬜ **H** Shared store (T12, T13) · ⬜ **I** Inert deploy (T14)
- ⬜ **J** Runner core (T15) · ⬜ **K** Verify + review (T16) · ⬜ **L** Coverage + reconcile (T17) → **HG-4** (T18)
- ⬜ **M** SK corpus (T19) · ⬜ **N** CS corpus + spot-check (T20)
- ⬜ **O** Servable languages, soft (T21) · ⬜ **P** iOS picker (T22) · ⬜ **Q** Harden validators (T26) after **HG-6**
- ⬜ **R** Gate on (T23) after **HG-5** · ⬜ **S** Serve-path deletion (T24) after **HG-7** · ⬜ **T** Cache retirement (T25)

*When a session lands, add a "Session X delivered — exact symbols for Y" note here (issue-61 convention) so the next session imports the real names instead of guessing: A owes J the batch adapter's submit/poll/retrieve signatures; D+E owe K the four verification entry points; G owes H+J the model class names and column types; H owes J+K+R `get_translations` and the `$contains` key spelling.*
