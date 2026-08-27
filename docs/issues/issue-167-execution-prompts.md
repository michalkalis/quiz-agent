# Issue #167 — Execution plan + ready-to-paste session prompts

**Created:** 2026-08-26 — Phase 6 (Split) of `/prepare-issue`. #167 is **large** (14 tasks across backend orchestrator, two new CLI scripts, iOS, and a live paid runbook) and carries a **founder gate in the middle** (167.13), so it is cut into session-sized, independently-committable chunks. Reversibility class **`a` (reversible)** — no migration, no schema, no auth/payments, prod flags untouched. Each chunk below has a self-contained prompt: open a fresh session, paste the fenced block, go.

> Parent plan: [`issue-167-entertainment-recent-events-questions.md`](issue-167-entertainment-recent-events-questions.md) — read its `## Resolved design decisions` (D1–D10) once; the per-session prompts cite decisions by id and do not restate them.

---

## Recon snapshot — what the codebase already gives us

All paths relative to `apps/quiz-pack-api/` unless stated. Verified 2026-08-26.

**Orchestrator / seam (D2):**
- `app/orchestrator/pack_generator.py:136-139` — today `direct_generation = (order.generation_mode == "direct") or feature_flags.direct_generation_default()`. The `or` is why `"grounded"` is silently ignored.
- `app/db/models/order.py:50` — `generation_mode` column exists; `:113-114` — CHECK constraint already allows exactly `direct|grounded`. **No migration needed.**
- `app/feature_flags.py:261-269` — `DIRECT_GENERATION` default **on** since #166 (`81825633`).
- `app/orchestrator/stages/sourcing.py:89-93` — early return with `ctx.facts=[]` when `ctx.direct_generation`. `:80-86` — `_forced_topics` path used by `--topics`.
- `app/orchestrator/stages/generation.py` — `:214` sends `source_facts=ctx.facts or None`; `:299-305` expiry stamping; `:480` ungrounded-drop loop; `:496-510` fallback-attribution drop; `:536-551` F8 (`source_url` required, `logical_puzzle` exempt); `:196` `OPEN_SHAPE_FRACTION=0.04`.

**Generation (D3):**
- `app/generation/advanced_generator.py:51-57` `_CATEGORY_PROMPT_FILES` (entertainment → v1 today); `:65-72` `_REQUIRED_FACT_FIRST_PLACEHOLDERS` (6 keys); `:380-395` boot-time placeholder check; `:1080-1101` `use_fact_first` + category→prompt dispatch; `:906-941` `_attribute_sources` (fills `source_excerpt` only when the model emitted no URL).
- `prompts/question_generation_entertainment_v2.md` — 17 placeholders, all 6 required ones present (verified in D3). v1 stays as one-line rollback.

**Taxonomy (D7):**
- `app/generation/classification.py:17-25` `CATEGORIES` (no `entertainment`); `:54-68` `normalize_category()` collapses unknown → `"general"`.
- iOS **two** mirrors: `apps/ios-app/Hangs/Hangs/Utilities/Config.swift:96-106` (`categoryOptions: [(id: String?, display: String)]`, `String(localized:)` rows) and `apps/ios-app/Hangs/Hangs/Models/QuizSettings.swift:225-229` (`categoryOptions: [String?]`, comment says "Mirrors `Config.categoryOptions`" — enforced by nothing today).
- ⚠️ **Localization:** the repo has **exactly one** string source, `apps/ios-app/Hangs/Hangs/Localizable.xcstrings` — **no `.strings` files at all** (so a `find … -name '*.strings'` check is vacuous; issue-155 precedent). Structure: `.strings["<en key>"].localizations.sk.stringUnit.value`, `sourceLanguage: "en"`, 524 keys. Existing sibling to copy: `.strings["Sports Mix"]` → `sk` = `"Športový mix"`, state `translated`.

**Sourcing (D4/D5):**
- `app/sourcing/fact_sourcer.py:34-39` inline `ENABLE_NEWS_SOURCING` read; `:42-105` `gather_facts`; `:100-105` `FactBatch.facts_per_topic`.
- `app/sourcing/web_search_source.py:20-107` domain credibility classifier; `:113-116` `TAVILY_API_KEY` required; `:148-156` news-mode narrowing (`topic="news"`, `time_range="week"`) — **must stay off** (D4).
- `app/sourcing/models.py:78-84` — fact `excerpt`/`text` fields the offline join reads.
- **Recipe to copy:** `scripts/run_d21b_arms.py:108-128` (`_source`) — the proven "topics → FactSourcer → JSON" shape.

**CLI (`scripts/generate_pack.py`):**
- `:185` order construction; `:605` existing `--direct` (⚠️ **no mutually-exclusive group exists yet — 167.2 creates it**); `:535-540` `--target-count` (NOT `--count`); `:577-584` `--topics`; `:559-568` `--dedup-store` default `noop`; `:298-302` `EXPIRY_CLASSIFICATION` read; `:318-322` sourcing-stage ternary (skipped entirely when `--facts-file` is given); `:241-252` `_FactsFileSourcingStage` (**defines the fact-file format**: `{"topics": [...], "facts": [...]}`); `:355-372` `_write_out` (plain JSON array of full `Question.model_dump`, all `pending_review`); `:449-461` `--dump-facts` (writes only *after* a successful run — why D4 needs a separate script).

**Dedup helpers to import, never reimplement (167.7):**
- `app/orchestrator/stages/dedup.py` — `_tokenize`, `_jaccard`, `_fact_key` (`:260-272`), `_fact_tokens`, `DEFAULT_IN_BATCH_JACCARD_THRESHOLD` (`:60`, 0.60), `DEFAULT_FACT_JACCARD_THRESHOLD` (0.35), same-fact overlap check `:164-174`. All take a **`Question` instance**, not a dict.

**Import + gates:**
- `scripts/import_questions_json.py:60-73` — #158 fail-closed gate (`held_for_review` / `verified=False` never import, at any `--review-status`).
- `packages/shared/quiz_shared/models/question.py:239-240` — `expires_at`/`freshness_tag` survive the JSON round-trip; `:190-191` `question_to_row` maps them.
- `apps/quiz-agent/app/retrieval/question_retriever.py:119,129` — live serve-time `is_expired()` filter (no-op today; the pilot is its first real input); `:246` approved + `pack_id IS NULL` serving filter.

**Rating web:** `scripts/rating_page/build_page.py` (offline), `publish_batch.py` (⚠️ `:77-82` `SystemExit` if `--admin-key` is missing), `export_ratings.py`. Prod target `https://quiz-pack-api.fly.dev`; `/web/rate/{batch_id}` is not admin-gated (#154).

**Tests:** `tests/orchestrator/`, `tests/scripts/test_generate_pack_flags.py`, `tests/generation/`, `tests/sourcing/`. iOS: `HangsTests` (Swift Testing). Run backend from `apps/quiz-pack-api/` with `uv run --no-sync` (repo root-build flake — `project_uv_run_root_build_flake`); ruff via `uvx ruff check`.

**⚠️ Environment gotchas:**
- `TAVILY_API_KEY` and `QUIZ_PACK_ADMIN_API_KEY` are **both present** in the repo-root `.env` (verified 2026-08-26, names only). The `.env` lives at the **repo root**, not inside a git worktree — if you run Session E from a worktree, confirm the key resolution before the paid run.
- `QUIZ_PACK_ADMIN_API_KEY` ≠ `ADMIN_API_KEY`. The latter is quiz-agent's and returns **401** against the deployed quiz-pack-api.
- Prod flags: `fly.toml` sets **none** of `EXPIRY_CLASSIFICATION` / `ENABLE_NEWS_SOURCING` / `DIRECT_GENERATION` → the pilot's `EXPIRY_CLASSIFICATION=1` is a **shell-local** var for one CLI run and changes nothing in prod.

---

## Locked decisions (carry into every session)

Lifted verbatim by id from the parent plan's `## Resolved design decisions` and `## Founder decisions (2026-08-26, in-session — locked)`.

| # | Decision |
|---|---|
| **Founder 1** | Question type = **semi-stable post-cutoff facts first** (producer rosters, new albums/films, awards). Fresh news (14 d TTL) **explicitly deferred** — leave room, do NOT build. |
| **Founder 2** | Expiry handling = **serve-time filter only** (existing `is_expired()`). No auto-archive job now; recorded as a follow-up TODO. |
| **Founder 3** | Entertainment becomes a **user-visible** category: backend taxonomy + iOS mirror + picker + translations (xcstrings sync required). |
| **Founder 4** | Volume = **pilot ~30 questions** into corpus stock; founder personally rates before any bigger batch. |
| **Founder 5** | **Locked topic list** (6 themes × ~5 questions), verbatim: `music producers and their artists, 2026 album releases, 2026 awards and nominations (Oscars, Grammys), new 2026 films and series, 2026 tours and festivals, 2026 streaming hits`. **Reference date "post-cutoff" = year 2026** (Fable 5 cutoff Jan 2026). |
| **D1** | The class is *post-cutoff settled facts*, not news. Such a fact classifies as **`evergreen` → `freshness_tag = NULL`** — identical to a real evergreen row and to a classifier fail-safe. **`freshness_tag` therefore cannot gate this class**; a separate filter must (D6). |
| **D2** | `generation_mode` becomes authoritative **both ways**: `"direct"` → True, `"grounded"` → False, `NULL` → global default. App/API path never sets the column → stays `NULL` → byte-identical behaviour. No migration. |
| **D3** | Promote `entertainment` → `question_generation_entertainment_v2.md` in `_CATEGORY_PROMPT_FILES`. v1 is not deleted (one-line rollback). |
| **D4** | **No `news_mode`.** Recency is carried by the locked topic list, not the provider mode. `FactSourcer(enable_opentdb=False)` — **Wikipedia stays ON** (deliberate deviation from D21b, which was written for a weekly news window). Sourcing is a **separate script run BEFORE generation** (`scripts/source_facts.py`); `--dump-facts` cannot substitute (it writes only after a successful run). Every generation command carries `--grounded`, even with `--facts-file` — direct mode disables both attribution gates (ungrounded-drop + F8), and D6's offline join depends on them. Thin-yield gate: **< 40 facts → exit 1**. |
| **D5** | Provider = **Tavily** for the pilot (only implemented sourcing source; credibility classifier is built on it). Whether OpenAI Responses `web_search` can also serve as *sourcing* is the single open external question — **does not block the pilot**, must be closed before any scale-up or before cancelling the Tavily plan. |
| **D6** | **Post-cutoff acceptance filter** (`scripts/filter_postcutoff.py`, fully offline) is the real gate. Accept if (1) a year token **≥ 2026** appears in `question`/`answer`/**or the excerpt of the fact it came from**, **and** (2) `freshness_tag != "current"`. Excerpt leg is **best-effort**, joined offline from the fact file by normalized `source_url`. Remedy when `accepted < 20`: **exactly one** repeat round with narrower topic phrasings, second round filtered with `--merge-with` for cross-round uniqueness; still < 20 → **escalate to founder in-session**, never publish a short batch as done, never lower the bar yourself. `EXPIRY_CLASSIFICATION=1` is **telemetry only** for the pilot run. |
| **D7** | Backend `CATEGORIES` + **both** iOS mirrors (`Config.categoryOptions` and `QuizSettings.categoryOptions`) change together. `xcstringstool sync` is mandatory. **No aliases** added to `_CATEGORY_ALIASES`. |
| **D8** | Three segments with an explicit agent/founder boundary. **Segment 1 (agent, terminal)** ends at a published rating batch of **≥ 20 post-filter rows** + saved mapping + `facts_167.json`. **Segment 2** is the founder's rating. **Segment 3** is a *separate* agent run after the rating. |
| **D9** | Class **`a` — reversible.** No DB migration, no schema, prod flags untouched, ~30 corpus rows revertable via `scripts/archive_questions.py`. The only sticky part is **product**, not technical: a category the user has seen in the picker cannot be withdrawn without a UX regression — which is exactly why it is bound to Founder decision 3. |
| **D10** | Pilot runs on canonical **Fable 5** deliberately (one variable at a time). Entertainment questions **must not** become the eval set of the cheaper-gen-model blind test. `source_facts.py` also delivers the write half of the Anthropic Batch API regrow seam. |

---

## Session breakdown

| Session | Tasks | Risk | Notes |
|---|---|---|---|
| **A — Backend seams + prompt + taxonomy** | 167.1 · 167.2 · 167.3 · 167.4 | Low | One pytest run. Four one-to-few-line changes, each with its own test. **[parallel-safe]** with B/C/D. |
| **B — `source_facts.py`** | 167.5 | Low | New standalone script + mocked-`FactSourcer` tests. Touches no shared path. **[parallel-safe]** with A/C/D. |
| **C — `filter_postcutoff.py`** | 167.6 · 167.7 | Low | New standalone script, both modes, in one session (167.7 is the same file's second mode). **[parallel-safe]** with A/B/D. |
| **D — iOS category + Slovak string** | 167.8 | Low | Both mirrors + parity test + xcstrings sk value. **[parallel-safe]**, but prefer landing next to A so the two taxonomies ship together. |
| **E — Pilot runbook, Segment 1** | 167.9 · 167.10 · 167.11 · 167.12 | **Med-High** | **[blocked on A + B + C merged.]** Spends real money (Tavily + Fable 5) and writes to the **prod** rating web. Terminal agent state. |
| *(gate)* | **167.13 [F]** | — | **Founder rating.** Not an agent session — see Human prerequisites. |
| **F — Segment 3, import + class bar** | 167.14 | Low | **[blocked on 167.13.]** Separate agent run after the rating. |

Dependency chain: `A ∥ B ∥ C ∥ D` → `E` → `167.13 [F]` → `F`.

---

## Human prerequisites

1. **Before Session E — credentials (already satisfied, re-verify).** `TAVILY_API_KEY` and `QUIZ_PACK_ADMIN_API_KEY` were both confirmed present in the repo-root `.env` on 2026-08-26. Session E must still check them itself and **fail loud** rather than publish without them (`publish_batch.py:77-82` exits on a missing key; `ADMIN_API_KEY` is the wrong key and yields 401 on prod).
2. **Between E and F — founder rating (167.13).** Founder opens `https://quiz-pack-api.fly.dev/web/rate/<batch_id>?rater=michal` (the URL Session E prints) and rates the batch. The agent waits for nothing and starts nothing until the founder says the rating is done. Ratings come out via `scripts/rating_page/export_ratings.py`.
3. **In Session F — the class quality bar** (Phase-1 open question 6) is a **product** decision: agree it with the founder in-session, do not pick a number alone.

---

## Ready prompt — Session A (backend seams + prompt + taxonomy)

```
Work on issue #167 (entertainment questions from recent events), Session A only: tasks 167.1, 167.2, 167.3, 167.4 + their tests. Do NOT write source_facts.py or filter_postcutoff.py (Sessions B/C), do NOT touch iOS (Session D), and do NOT run any live generation or sourcing (Session E). Commit per task, push, open one PR.

Read first (already mapped — do not re-map the repo):
- docs/issues/issue-167-execution-prompts.md → "Recon snapshot" + "Locked decisions" (esp. D2, D3, D4, D7).
- apps/quiz-pack-api/app/orchestrator/pack_generator.py:130-145
- apps/quiz-pack-api/app/db/models/order.py:45-55 and :110-118 (column + CHECK constraint already exist)
- apps/quiz-pack-api/scripts/generate_pack.py:180-190 and :595-615 (--direct lives at :605; there is NO mutually-exclusive group yet)
- apps/quiz-pack-api/app/generation/advanced_generator.py:51-72 and :380-395
- apps/quiz-pack-api/app/generation/classification.py:17-25 and :54-68
- apps/quiz-pack-api/tests/scripts/test_generate_pack_flags.py and tests/generation/test_classification.py (existing test idiom)

Build (one commit each):
1) 167.1 — In pack_generator.py:136-139 replace the `or` expression with a three-way resolution: order.generation_mode == "direct" -> True; == "grounded" -> False; NULL/absent -> feature_flags.direct_generation_default(). No migration. Test tests/orchestrator/test_pack_generator.py::test_generation_mode_resolves_over_global_default — 3 column values x both global-default states (6 asserts). Intent to encode: "an explicit order overrides the global default; NULL inherits it, so the app/API path is byte-identical."
2) 167.2 — In scripts/generate_pack.py CREATE a mutually-exclusive group (ap.add_mutually_exclusive_group()), move the existing --direct into it, add --grounded. At :185: generation_mode = "direct" if args.direct else ("grounded" if args.grounded else None). Do NOT change any sourcing config in this file (D4). Test in tests/scripts/test_generate_pack_flags.py::test_grounded_flag_sets_generation_mode: --grounded -> "grounded", --direct -> "direct", neither -> None, both -> argparse SystemExit code 2.
3) 167.3 — _CATEGORY_PROMPT_FILES: map "entertainment" to question_generation_entertainment_v2.md. Do NOT delete v1 (one-line rollback). Tests: tests/generation/test_category_prompt_dispatch.py (dispatch points at v2) and tests/generation/test_entertainment_prompt.py (v2 carries all 6 _REQUIRED_FACT_FIRST_PLACEHOLDERS from advanced_generator.py:65-72, so the boot-time check at :380-395 passes).
4) 167.4 — Add "entertainment" to CATEGORIES in app/generation/classification.py. Do NOT add anything to _CATEGORY_ALIASES (D7). Test in tests/generation/test_classification.py: normalize_category("entertainment") == "entertainment" (this assertion fails today — it returns "general").

Done = from apps/quiz-pack-api/: `uv run --no-sync pytest tests/orchestrator/test_pack_generator.py tests/scripts/test_generate_pack_flags.py tests/generation -q` exit 0, plus the full `uv run --no-sync pytest tests/ -q` green, `uvx ruff check` clean. Branch feat/167-entertainment-seams, push, open a PR, address the Claude Code Review findings, squash-merge when green. Then tick 167.1-167.4 in docs/issues/issue-167-entertainment-recent-events-questions.md and update the #167 line in docs/todo/TODO.md.
```

---

## Ready prompt — Session B (`scripts/source_facts.py`)

```
Work on issue #167, Session B only: task 167.5 — the new standalone sourcing script + its tests. Do NOT modify scripts/generate_pack.py or any shared pipeline path (that is deliberate — see D4). Do NOT run it against the live Tavily API in this session; tests mock FactSourcer. Commit, push, open a PR.

Read first:
- docs/issues/issue-167-execution-prompts.md → "Recon snapshot" (Sourcing + CLI) + "Locked decisions" D4, D10.
- apps/quiz-pack-api/scripts/run_d21b_arms.py:108-128 — the proven recipe (_source). Copy its shape.
- apps/quiz-pack-api/app/sourcing/fact_sourcer.py:34-39, :42-105, :100-105 (FactBatch.facts_per_topic)
- apps/quiz-pack-api/scripts/generate_pack.py:241-252 — _FactsFileSourcingStage: this DEFINES the output format you must write, {"topics": [...], "facts": [...]}.
- apps/quiz-pack-api/tests/scripts/test_generate_pack_flags.py — CLI test idiom.

Build scripts/source_facts.py:
- args: --topics (one comma-separated string, same shape generate_pack.py --topics uses) and --out (path).
- constructs FactSourcer(enable_opentdb=False). Wikipedia stays ENABLED — that is a deliberate deviation from D21b, justified in D4; do not "fix" it to match run_d21b_arms.py.
- must NOT set or read ENABLE_NEWS_SOURCING. No news mode (D4).
- gathers facts over the topics, writes {"topics": [...], "facts": [...]} to --out.
- thin-yield gate: fewer than 40 facts total -> print a per-topic tally (FactBatch.facts_per_topic) to stdout naming the weak topics, and exit(1). 40+ -> exit(0).

Tests tests/scripts/test_source_facts.py with FactSourcer mocked (no network):
(a) 40+ facts -> exit 0 AND the written JSON is loadable by _FactsFileSourcingStage without error (import it and feed it the file — this is the criterion that actually pins the format);
(b) 39 facts -> exit 1 and stdout names the weakest topics from the tally;
(c) FactSourcer was constructed with enable_opentdb=False.
Encode the intent in the test names/comments: (a) the fact file must be consumable by the generator, (b) a thin yield must fail loud rather than silently produce a small batch.

Done = from apps/quiz-pack-api/: `uv run --no-sync pytest tests/scripts/test_source_facts.py -q` exit 0 and full `uv run --no-sync pytest tests/ -q` green, `uvx ruff check` clean. Branch feat/167-source-facts, push, PR, address review, squash-merge. Tick 167.5 in the issue file.
```

---

## Ready prompt — Session C (`scripts/filter_postcutoff.py`)

```
Work on issue #167, Session C only: tasks 167.6 + 167.7 — the new offline post-cutoff filter script, both modes, in one session (167.7 is the same file's second mode). Do NOT touch the importer, the pipeline, or generate_pack.py. Do NOT run any live generation. Commit per task, push, open a PR.

Read first:
- docs/issues/issue-167-execution-prompts.md → "Recon snapshot" (dedup helpers, CLI _write_out format) + "Locked decisions" D1, D6.
- apps/quiz-pack-api/scripts/generate_pack.py:355-372 — _write_out: the input you parse is a PLAIN JSON ARRAY of full Question.model_dump dicts.
- apps/quiz-pack-api/scripts/generate_pack.py:241-252 — the fact-file format you read with --facts-file.
- apps/quiz-pack-api/app/sourcing/models.py:78-84 — fact excerpt/text fields.
- apps/quiz-pack-api/app/orchestrator/stages/dedup.py — _tokenize, _jaccard, _fact_key (:260-272), _fact_tokens, DEFAULT_IN_BATCH_JACCARD_THRESHOLD (:60), DEFAULT_FACT_JACCARD_THRESHOLD, and the same-fact overlap check at :164-174.
- packages/shared/quiz_shared/models/question.py — the shared Question model.

Build scripts/filter_postcutoff.py — FULLY OFFLINE, it must never make a network call:
1) 167.6 — mode 1: read the batch JSON positional arg + --facts-file; write <stem>_accepted.json / <stem>_rejected.json and print a tally. Predicate (D6): accept iff (a) a year token >= 2026 appears in `question` OR `answer` OR the excerpt of the fact the row came from, AND (b) freshness_tag != "current". For a row with no source_excerpt, look the excerpt up offline in the fact file by normalized source_url. Every rejected row carries a `reason`: "no_2026_token" or "freshness_current".
2) 167.7 — mode 2: --merge-with <already-accepted.json>. A round-2 row is dropped with reason "duplicate_round1" if, against ANY already-accepted row, (a) _fact_key matches, OR (b) Jaccard of question tokens >= DEFAULT_IN_BATCH_JACCARD_THRESHOLD, OR (c) Jaccard of _fact_tokens >= DEFAULT_FACT_JACCARD_THRESHOLD. IMPORT these helpers from app.orchestrator.stages.dedup — do NOT reimplement or copy them (one definition, no threshold drift). They take a Question INSTANCE, not a dict: rehydrate every row from both JSONs via Question.model_validate(row) before handing it to a helper; never pass a raw dict.

Tests tests/scripts/test_filter_postcutoff.py:
- 167.6: accept via question/answer text; accept via the offline-joined excerpt; reject with no year token; reject on freshness_tag == "current"; a row whose model-emitted source_url is absent from the fact file falls back to question/answer text (this is an ACCEPTED degradation, assert it rather than treating it as a bug).
- 167.7: one pair per leg (fact-key / question-Jaccard / fact-token-Jaccard) plus one near-miss pair that must survive; plus assert filter_postcutoff._jaccard.__module__ == "app.orchestrator.stages.dedup" (this is the assertion that falsifies a silent fork of the thresholds).
Intent to encode: the filter is the ONLY gate measuring the defining property of this question class (freshness_tag provably cannot — D1), and the merge mode is the only cross-round uniqueness guard (the pipeline dedup store is a noop here — D6).

Done = from apps/quiz-pack-api/: `uv run --no-sync pytest tests/scripts/test_filter_postcutoff.py -q` exit 0 and full `uv run --no-sync pytest tests/ -q` green, `uvx ruff check` clean. Branch feat/167-postcutoff-filter, push, PR, address review, squash-merge. Tick 167.6 + 167.7 in the issue file.
```

---

## Ready prompt — Session D (iOS category + Slovak string)

```
Work on issue #167, Session D only: task 167.8 — make `entertainment` a user-visible category on iOS. Backend-only work is Sessions A-C; do not touch apps/quiz-pack-api. Commit, push, open a PR.

Read first:
- docs/issues/issue-167-execution-prompts.md → "Recon snapshot" (Taxonomy) + "Locked decisions" D7, Founder 3.
- apps/ios-app/Hangs/Hangs/Utilities/Config.swift:96-106 — categoryOptions: [(id: String?, display: String)], each row uses String(localized:...) with a comment.
- apps/ios-app/Hangs/Hangs/Models/QuizSettings.swift:225-229 — categoryOptions: [String?], the settings-validation mirror.
- apps/ios-app/Hangs/Hangs/Localizable.xcstrings — the ONLY string source in the repo (there are no .strings files). Look at .strings["Sports Mix"] for the exact shape to copy.
- .claude/rules/ios.md for build/test commands and schemes.

Build:
1) Add ("entertainment", String(localized: "Entertainment", comment: "Quiz category option")) to Config.categoryOptions, and "entertainment" to QuizSettings.categoryOptions. Both in the same commit — if they drift, a saved "entertainment" setting fails validation. Do NOT change the picker UI: it reads the array.
2) From apps/ios-app/ run `xcstringstool sync Hangs/Localizable.xcstrings` so the new key is registered, then ADD the Slovak translation for it (sk stringUnit value, state "translated"), matching how "Sports Mix" is done.
3) New parity test in HangsTests (Swift Testing): QuizSettings.categoryOptions == Config.categoryOptions.map { $0.id }. Use `.map { $0.id }`, NOT a \.id key path — a key path on a tuple label does not compile. Intent: "the two mirrors must not drift" — today only a code comment holds this.

Done = HangsTests green on the iOS 26 simulator, build clean, AND from apps/ios-app/: `jq -e '.strings["Entertainment"].localizations.sk.stringUnit.value | select(. != null and . != "")' Hangs/Localizable.xcstrings` exits 0, AND `git diff --exit-code Hangs/Localizable.xcstrings` exits 0 after a fresh xcstringstool sync (i.e. the sync is committed). Branch feat/167-ios-entertainment-category, push, PR, address review, squash-merge. Tick 167.8 in the issue file.
```

---

## Ready prompt — Session E (pilot runbook, Segment 1 — spends money, writes to prod)

```
Work on issue #167, Session E only: tasks 167.9, 167.10, 167.11, 167.12 — run the entertainment pilot end to end and publish the rating batch. Sessions A + B + C must be merged to main first (check before starting). This session SPENDS REAL MONEY (Tavily + Fable 5) and PUBLISHES TO PROD. Do NOT import anything into the corpus — that is Session F, after the founder's rating. Do NOT lower any threshold on your own.

Read first:
- docs/issues/issue-167-execution-prompts.md → "Recon snapshot" (all) + "Locked decisions" (esp. Founder 5, D4, D6, D8) + "Human prerequisites".
- docs/issues/issue-167-entertainment-recent-events-questions.md → tasks 167.9-167.12 and the ## Acceptance runbook table (A11-A15) — those are your done-criteria verbatim.

Preflight (fail loud, before spending anything):
- TAVILY_API_KEY and QUIZ_PACK_ADMIN_API_KEY must resolve from the repo-root .env. QUIZ_PACK_ADMIN_API_KEY is NOT ADMIN_API_KEY (that one is quiz-agent's and 401s against prod). If either is missing, STOP and ask the founder in-session — do not proceed, do not substitute.

Run from apps/quiz-pack-api/:
1) 167.9 — sourcing FIRST, as its own step:
   uv run --no-sync python scripts/source_facts.py --topics "music producers and their artists, 2026 album releases, 2026 awards and nominations (Oscars, Grammys), new 2026 films and series, 2026 tours and festivals, 2026 streaming hits" --out facts_167.json
   That topic string is a locked founder decision — paste it verbatim, do not reword or extend it. On exit 1 (thin yield, <40 facts): EXACTLY ONE retry with narrower phrasings of the topics the tally named as weakest. If the second attempt is still <40, escalate to the founder in-session and stop; never lower the 40 threshold.
2) 167.10 — generate + verify/score:
   EXPIRY_CLASSIFICATION=1 uv run --no-sync python scripts/generate_pack.py --grounded --category entertainment --facts-file facts_167.json --target-count 30 --dry-run --out pilot_167.json
   --grounded is MANDATORY even with --facts-file: without it both attribution gates (ungrounded-drop and F8) are off, and the offline join in step 3 depends on them. It is --target-count, not --count. EXPIRY_CLASSIFICATION=1 is shell-local telemetry; do not put it in fly.toml. The run is fail-loud by design: an empty fact set raises F8 and no batch is produced — that is correct, not a bug to work around. Then run the offline verify and /score-questions.
3) 167.11 — post-cutoff filter:
   uv run --no-sync python scripts/filter_postcutoff.py pilot_167.json --facts-file facts_167.json
   If accepted < 20: EXACTLY ONE repeat of steps 1-3 with narrower topic phrasings, and run round 2's filter with --merge-with pilot_167_accepted.json (cross-round uniqueness). Merged result is what counts toward >= 20. If still < 20 after that round, ESCALATE to the founder in-session with accepted/rejected counts and sample reasons, publish nothing, and stop — that is a valid terminal state for this session.
4) 167.12 — publish the rating batch (from apps/quiz-pack-api/), one arm, fixed seed 167, NO --dedupe-by-fact:
   uv run --no-sync python scripts/rating_page/build_page.py --arm e-2026=pilot_167_accepted.json --seed 167 \
     --batch-id 167-entertainment-pilot --title "Entertainment pilot #167" --out-dir ../../docs/testing/runs/167-entertainment-pilot
   uv run --no-sync python scripts/rating_page/publish_batch.py --arm e-2026=pilot_167_accepted.json --seed 167 \
     --title "Entertainment pilot #167" --base-url https://quiz-pack-api.fly.dev --admin-key "$QUIZ_PACK_ADMIN_API_KEY" \
     --rater michal --save-mapping ../../docs/testing/runs/167-entertainment-pilot/mapping_published.json

Done = the parent issue's A11-A15 all hold: facts_167.json has >= 40 facts and is OLDER than pilot_167.json; zero rows with a null source_url outside the logical_puzzle exemption; pilot_167_accepted.json has >= 20 rows (or a documented escalation); publish_batch.py exited 0 and printed a batch_id; mapping_published.json is non-empty; and curl -s -o /dev/null -w '%{http_code}' "https://quiz-pack-api.fly.dev/web/rate/<batch_id>?rater=michal" returns 200.
Then report to the founder, in-session: the rating URL, accepted/rejected counts broken down by reason (including duplicate_round1), 2-3 sample false-negative rejects (this is the D6 measurement of the filter's false-negative rate — it has never been measured), and the freshness_tag distribution (expectation: mostly evergreen/NULL; lots of "current" would mean the generator drifted into the news class). Commit facts_167.json, pilot_167*.json and the run dir, push, PR. THIS IS WHERE THE AGENT RUN ENDS — the founder rates next (167.13). Do not start Session F.
```

---

## Ready prompt — Session F (Segment 3 — import after the founder's rating)

```
Work on issue #167, Session F only: task 167.14 — import the rated-and-accepted rows into the corpus and close out the class quality bar. PRECONDITION: the founder has finished rating the batch (167.13) and told you so. If they have not, stop and wait — do not import anything.

Read first:
- docs/issues/issue-167-execution-prompts.md → "Locked decisions" D8, Founder 4, and "Human prerequisites" item 3.
- apps/quiz-pack-api/scripts/rating_page/export_ratings.py — how the ratings come out.
- apps/quiz-pack-api/scripts/import_questions_json.py:60-73 — the #158 fail-closed gate.
- docs/issues/issue-167-entertainment-recent-events-questions.md → ## Acceptance criteria A16, A17.

Build:
1) Export the founder's ratings, and assemble the set of rows the founder accepted.
2) From apps/quiz-pack-api/: uv run --no-sync python scripts/import_questions_json.py <accepted-after-rating.json> --review-status approved --execute
   Expect losses at the #158 gate: any row with held_for_review or verified=False never imports at ANY --review-status. That is the intended filter for this error-prone class, not a bug — report the count, do not route around it. The web review UI is retired (410).
3) With the founder, agree the quality bar for this class (Phase-1 open question 6) and whether a bigger batch follows. This is a PRODUCT decision — ask in-session, do not pick a number yourself. Record the answer in the issue file or in the corpus-refresh-cadence TODO item.

Done = A16: `SELECT count(*) FROM questions WHERE category='entertainment' AND review_status='approved' AND pack_id IS NULL` > 0 (no count is fixed in advance — the founder's rating sets it), and A17: the class quality bar is written down. Commit, push, PR, then mark #167 done in docs/issues/INDEX.md and docs/todo/TODO.md, and file the three ## Follow-ups (auto-archive job, the D5 web pass, refresh cadence) as TODO items.
```

---

## Status

- ✅ Split done 2026-08-26 (this doc). Decisions Founder 1-5 + D1-D10 locked; class `a` confirmed (no migration, no schema, prod flags untouched).
- ✅ Session A — backend seams + prompt + taxonomy (167.1-167.4) · delivered 2026-08-27
- ⬜ Session B — `source_facts.py` (167.5)
- ✅ Session C — `filter_postcutoff.py` (167.6-167.7), delivered 2026-08-27 — see the note below.
- ✅ Session D — iOS category + Slovak string (167.8) · delivered 2026-08-27
- ⬜ Session E — pilot runbook Segment 1 (167.9-167.12) · blocked on A+B+C
- ⬜ 167.13 `[F]` — founder rating (not an agent session)
- ⬜ Session F — Segment 3 import + class bar (167.14) · blocked on 167.13

> When a session lands, add a short **"Session X delivered — exact symbols for Y"** note here (issue-61 convention) so the next session does not have to re-read the diff. Session B owes E the exact `source_facts.py` CLI signature; Session C owes E the exact output filenames and `reason` vocabulary.

### Session A delivered — exact symbols

- **Mode resolution** is `app/orchestrator/pack_generator.py::_resolve_direct_generation(generation_mode: str | None) -> bool` — module-level, called from `PackGenerator.run` when building `OrderContext.direct_generation`. `"direct"` → True, `"grounded"` → False, anything else (incl. `None`) → `feature_flags.direct_generation_default()`.
- **CLI:** `--grounded` sits in an unnamed `parser.add_mutually_exclusive_group()` alongside `--direct` in `scripts/generate_pack.py::_parse_args`. Both flags together → argparse exit 2. `_build_order` sets `generation_mode="direct" if args.direct else ("grounded" if args.grounded else None)`.
- ⚠️ **Carried cost for anyone touching `_build_order`:** `scripts/validate_generation.py::_order_namespace` hand-builds that namespace and now also passes `grounded=False`. A new `_build_order` attribute must be added there too (its regression test `test_order_namespace_satisfies_build_order` catches it, but only in a full run).
- **Prompt:** `_CATEGORY_PROMPT_FILES["entertainment"] == "question_generation_entertainment_v2.md"` (`app/generation/advanced_generator.py`). The dispatched `prompt_version` string is unchanged: `"v3_fact_first_entertainment"`. v1 stays on disk; rollback is that one dict value.
- **Taxonomy:** `"entertainment"` appended last in `CATEGORIES` (`app/generation/classification.py`), no `_CATEGORY_ALIASES` entry. This closes the gap Session D flagged — `normalize_category("entertainment")` no longer collapses to `"general"`.
- **Owed to Session E:** `--grounded` is now honoured end-to-end, so 167.10's command works as written. Nothing in this session changed sourcing config or any prod flag default.

### Session D delivered — exact symbols

- **Category id `"entertainment"`** is now in **both** iOS mirrors, appended last in each so the order stays parallel: `Config.categoryOptions` (`apps/ios-app/Hangs/Hangs/Utilities/Config.swift`) and `QuizSettings.categoryOptions` (`apps/ios-app/Hangs/Hangs/Models/QuizSettings.swift`). `HomeView.swift:342` renders the picker straight off `Config.categoryOptions` — no UI change was needed.
- **String catalog key** is `"Entertainment"` (English source key, comment `Quiz category option`), `sk` = **`"Zábava"`**, state `translated`, in `apps/ios-app/Hangs/Hangs/Localizable.xcstrings`.
- ⚠️ **Correction to the recon snapshot / the Session D prompt:** the catalog path from `apps/ios-app/` is `Hangs/Hangs/Localizable.xcstrings`, **not** `Hangs/Localizable.xcstrings` — the prompt's `xcstringstool sync` and `jq` commands silently no-op (`warning: Skipping sync … could not be read`) on the wrong path. Also `xcstringstool sync` **requires `--stringsdata`**, which only a build produces; the working invocation is a `xcodebuild build` first, then `xcstringstool sync <abs path to .xcstrings> --stringsdata <DerivedData>/Build/Intermediates.noindex/Hangs.build/Debug-Local-iphonesimulator/Hangs.build/Objects-normal/arm64/*.stringsdata --skip-marking-strings-stale`. Sessions touching strings should use that form.
- **Parity test:** `HangsTests/HomeCategoryMultiSelectTests.swift` → `"the two category mirrors must not drift"`, asserting `QuizSettings.categoryOptions == Config.categoryOptions.map { $0.id }`. Full `HangsTests`: 1014 tests / 183 suites green on iOS 26.5 (iPhone 17 Pro).
- **Still owed by Session A** for this to be end-to-end: `"entertainment"` in the backend `CATEGORIES` (`app/generation/classification.py`) — until then `normalize_category("entertainment")` collapses to `"general"`.

### Session C delivered — exact output filenames + reason vocabulary

`apps/quiz-pack-api/scripts/filter_postcutoff.py`, fully offline, exit code always `0` (the "< 20 accepted" escalation is the runbook's call, not the script's).

**CLI:** `filter_postcutoff.py <batch.json> [--facts-file FACTS] [--merge-with ACCEPTED]` — `<batch.json>` is the positional `generate_pack.py --out` file.

**Output filenames** (written next to the input, `<stem>` = the input's stem):

| Input | Accepted file | Rejected file |
|---|---|---|
| `pilot_167.json` | `pilot_167_accepted.json` | `pilot_167_rejected.json` |
| `pilot_167_r2.json` | `pilot_167_r2_accepted.json` | `pilot_167_r2_rejected.json` |

Both are plain JSON arrays in the same shape `_write_out` produces. Accepted rows are **byte-identical** to the input rows (no added keys) so `build_page.py` / `publish_batch.py` / the importer read them directly; rejected rows carry exactly one extra key, `reason`.

**`reason` vocabulary** (the complete set — exported as module constants `REASON_NO_YEAR`, `REASON_FRESHNESS_CURRENT`, `REASON_DUPLICATE_ROUND1`):

| `reason` | Meaning |
|---|---|
| `no_2026_token` | no year token ≥ 2026 in `question`, in the answer (MCQ keys resolved to option text), or in the joined fact excerpt |
| `freshness_current` | year leg passed but `freshness_tag == "current"` — the news class the pilot excludes |
| `duplicate_round1` | `--merge-with` only: duplicates an already-accepted row on `_fact_key`, question-Jaccard ≥ 0.60, or `_fact_tokens`-Jaccard ≥ 0.35 |

The year leg is checked first, so a row failing both legs is reported as `no_2026_token`.

**⚠️ `--merge-with` writes the UNION.** In merge mode `<stem>_accepted.json` contains the `--merge-with` rows first, then round-2 survivors — so the single file Session E publishes already *is* the merged result D6's "≥ 20 accepted" is counted on. The tally prints `merged total: N`. Round 1's own `*_accepted.json` is never modified.

**Stdout tally** (parse-free, for the 167.11 report): `input rows` / `accepted` / `rejected` / one indented line per `reason` present / `merged with` + `merged total` in merge mode / `wrote <path>` twice. Without `--facts-file` it prints a `WARNING: no --facts-file — excerpt leg of the predicate is off.` line; Session E always passes it.
