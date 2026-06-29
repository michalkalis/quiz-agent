# Issue #76 — `entertainment` category (pop-culture questions: evergreen + current/viral)

**Triage:** enhancement · **F-3a → `ready-for-agent`** (Ralph-runnable, dormant) · **F-3b → `ready-for-human`** (founder greenlight: recurring Tavily-news PAYG + always-on scheduler + first live `expires_at` write)

**Reversibility:** **F-3a = `a`** (commits-only, new prompt + category dispatch + topic-pool entries, all dormant behind the existing category seam — no schema/data migration, no auth/payment, no prod deploy, no corpus writes). **F-3b = higher-risk within `a`**: it **activates** the live serving read-path's *already-present* `expires_at` filter (by setting `expires_at` for the first time — the filter exists at `question_retriever.py:118`, verified Phase 2) and adds a **scheduler** (refresh/regenerate job) — no new migration (the expiry columns already exist) but it leaves pure-dormant, so it is **human-gated**, not Ralph-autonomous. (See Scope.)

**Created:** 2026-06-29 · **Founder:** Michal · **Parent:** [[issue-72-question-fun-engagement-redesign|#72]] follow-up **F-3** (promoted to its own plan file: #72 is over the file-size limit and F-3 is a sizable, product-shaped mini-project of its own).

## Why

Add a pop-culture **`entertainment`** category to question generation. Founder ask (2026-06-29, "zisti" → research first): a GLOBAL entertainment category covering **both evergreen** (famous films, music history, iconic actors) **and current/viral** (trending now, this week's release). The "surprise me"/no-category path lands on military/listicle facts today and never on pop-culture — entertainment is one of the most-wanted casual-trivia domains and is currently absent.

**Founder decisions already locked (2026-06-29):**
- Wants **BOTH** evergreen AND news/current as the end goal (not evergreen-only).
- Build **phased**: **F-3a (evergreen) first**, then **F-3b (current/viral)** — they are genuinely different-cost pipelines.
- Accepts the **4-bucket taxonomy** default (Film · Music & Artists · TV & Streaming · Viral/Trending).
- **TMDB ruled out** (ToS forbids commercial LLM pipelines); stay on **Tavily** (no new key/bill).

**Out of scope:** generating corpus content for release (that is [[issue-30-batch-generate-categories]], founder-owned, post-un-park); re-litigating the web-search provider (keep Tavily PAYG).

## Phase 1 research — DONE

Full research + the load-bearing internal/external findings + a phased build sketch live in
**[`docs/research/entertainment-category-f3-2026-06-29.md`](../research/entertainment-category-f3-2026-06-29.md)** (first-hand verified, prior session). That doc is the Phase-1 output; §2 (verified internal findings), §3 (prior-art / build-vs-adopt), §4 (sourcing cost+licensing), §5 (staleness control) and §6 (phased build) feed the Plan below.

## Scope

Both phases share one `entertainment` category but split on cost and on which seams they touch: **F-3a is generate-once evergreen that reuses every existing seam; F-3b is the recurring-cost current/viral pipeline that adds the one genuinely new moving part (a scheduler) and is the first code to write live `expires_at` data.**

### F-3a — evergreen entertainment (commits-only, dormant, Ralph-runnable)

In scope:
- New `prompts/question_generation_entertainment.md` — pop-culture tone, driving-safe answer rules, absolute phrasing. Written as a **fact-first** prompt (carries the `{facts_section}` + `{mcq_patterns_section}` placeholders) so it composes with the existing v3 machinery instead of replacing it.
- A **general `category → prompt` dispatch** in `AdvancedQuestionGenerator._build_batch_prompt` (`advanced_generator.py:676-691`): when the order's `categories[0]` is in a small `{category: prompt}` map, select that category's fact-first builder in place of the generic v3 one. The prompt is loaded alongside the others in `__init__` (`advanced_generator.py:163-204`). The category signal already arrives — `GenerationStage` passes `categories=[ctx.category]` (`generation.py:165`) — so **no orchestrator plumbing changes**.
- Tests + a small dry-run validation batch on an explicit `category="entertainment"` order.

Out of scope (F-3a): any current/viral content; any `expires_at`/`freshness_tag` writes; any new sourcing infra; **topic-pool entries (see C-a resolution below).** Evergreen entertainment is **already sourced for free** — OpenTriviaDB's `CATEGORY_MAP` (`opentriviadb_source.py:20-46`) already maps Film(11)/Music(12)/Television(14)/Entertainment(15)/Celebrities(26), with Wikipedia + Tavily covering the rest.

**C-a resolved (founder, 2026-06-29) — entertainment tone everywhere, delivered via explicit-category generation, NOT the topic pool.** The founder chose "tone in surprise-me too", correctly reasoning that questions are pre-generated and surprise-me *serving* just pulls from the DB regardless of category (verified: `question_retriever` omits the category filter when the session has no `preferred_categories`). The tone-bearing path is therefore: generate entertainment through an **explicit `category="entertainment"` order** → full tone + `category="entertainment"` baked in (verified chain `generation.py:165` `categories=["entertainment"]` → `advanced_generator.py:642,714`) → stored → surfaced in surprise-me serving. **Consequence — the ~10 topic-pool entries are dropped from F-3a.** Verified: a *no-category* generation run is one **mixed batch under `categories=None`** that the generator renders as `"general"` (`generation.py:164-165` derive topics/categories from `ctx.category`/`ctx.theme` only — the pool-sampled strings reach `gather_facts` for *sourcing* but never `_build_batch_prompt`; `topic_pool.json` entries carry no `category` field). Pool entries would thus generate **generic-tone `"general"` questions** — exactly what option-2 rejects — and applying per-topic tone inside a no-category mixed batch is the bigger change the founder explicitly declined. The corpus gets full-tone entertainment from explicit-category generation (#30 post-un-park); the pool is not the mechanism.

### F-3b — current/viral entertainment (recurring cost, human-gated)

In scope:
- **Recency-aware Tavily** behind a flag / a `NewsWebSearchSource`: add `topic=news` + `time_range=week` to the Tavily call (`web_search_source.py:42-47` passes no recency params today). Replaces the deleted `news_source.py` path — no new key/bill.
- **Set `expires_at` + `freshness_tag` at generation** by content-class, in `GenerationStage`'s per-question stamping loop (`generation.py:213-236`); they then flow unchanged through `question_to_row` (`db/models/question.py:184-185`) → PersistStage and `PgvectorQuestionStore.add`. Nothing sets them today.
- A **scheduled refresh/regenerate job** for the `current` tier (the new moving part; replaces the dead `scripts/expire_questions.py`, which imports the removed `apps/question-generator` and targets frozen ChromaDB).
- Absolute-phrasing prompt constraints + a `content_class` tag.

Out of scope (F-3b): **building a read-path expiry filter — it already exists.** `QuestionRetriever.get_next_question` already drops expired candidates in-memory via `Question.is_expired()` at `question_retriever.py:118` (primary) and `:128` (fallback); `is_expired()` (`question.py:225-235`) compares `expires_at > now` and is a no-op while `expires_at` is NULL. F-3b *activates* that filter by setting `expires_at`; it does not build it. (An optional SQL push-down in `PgvectorQuestionStore.search` (`pgvector_client.py:179-213`) is an efficiency nicety, not a correctness prerequisite.)

### Second-order interactions
- **(a) Existing category/sourcing system:** `category` today is a *sourcing* signal only (`sourcing.py:137-140` topic token; `generation.py:165` `categories=`), never a prompt selector. F-3a adds the first prompt-selecting use without disturbing the sourcing use. For the buckets to source well, the entertainment topics must surface the bucket names so OpenTriviaDB's Film/Music/TV/Celebrity categories activate (not only `entertainment`→15).
- **(b) F-1 curated topic pool:** the pool is a *static* file sampled only by the no-category CLI path, where the whole batch generates under `categories=None` → `"general"` (verified `generation.py:164-165`; pool strings reach sourcing only). So the pool **cannot** apply entertainment tone — per C-a (option-2: full tone everywhere) **no entertainment topics go in the pool at all.** Entertainment enters the corpus through explicit `category="entertainment"` generation (full tone), not the surprise-me pool. (Viral/current content was never pool-eligible regardless — it would rot in a static JSON; F-3b generates it on demand with expiry.)
- **(c) Parked generation:** both phases are inert until un-park — no paid generation runs, so no corpus rows are written either way. F-3a's value (pop-culture in the corpus) materializes only at un-park.
- **(d) Future categories:** the dispatch is a **general** `{category: prompt}` map, not an `entertainment` special-case (the provenance enum already anticipates `themed`/`kids` pipelines, `question.py:29`; the `_kids.md`/`_themed.md` prompt files exist but are unwired). Kids/themed/science later just register a prompt — same seam, no new branch. A dict is no more code than a hardcoded `if`, so general wins (Rule #1).
- **(e) Live read-path for F-3b expiry:** the filter is application-layer (`question_retriever.py:118,128`), correct, and dormant today; setting `expires_at` is what flips it live.

### Driving-safety constraints (both phases, enforced in the entertainment prompt)
1–4 spoken-word answers; no visual-recognition topics (comics/anime, "name the poster"); no list answers ("name all five nominees"). The existing 10-word answer cap (`generation.py` `_violates_answer_brevity`) is the hard backstop; the 1–4-word target is prompt-level guidance. Current content (F-3b) must use **absolute phrasing** with a year anchor ("In 2026, who won…"), never "current/latest/this year" — LLMs are temporally blind and a relative-time question rots silently (research §5).

## Resolved design decisions

1. **Phase it (F-3a evergreen → F-3b current/viral).** Founder-locked, and the two are genuinely different-cost pipelines: evergreen is generate-once on existing free/PAYG sources; current/viral adds ongoing Tavily-news spend + a regeneration scheduler (research §1, §6). Sequencing ships the low-risk, Ralph-runnable win behind the existing seam while the cost/scheduler commitment waits for an explicit founder go.

2. **4-bucket flat taxonomy: Film · Music & Artists · TV & Streaming · Viral/Trending.** One `category = "entertainment"`; the buckets are topics/tags inside it (Awards/Celebrities held as tags until volume justifies a split). Mirrors the Trivia Crack / Kahoot commercial model and stays driving-safe — no visual/list buckets (research §3). Boundary is clean: **buckets 1–3 evergreen → F-3a; bucket 4 (Viral/Trending) plus the current slice of 1–3 → F-3b.**

3. **General `category → prompt` dispatch, not an entertainment special-case.** A minimal `{category: prompt-template}` map consulted in `_build_batch_prompt` (`advanced_generator.py:676-691`); an unregistered category falls through to today's exact open/v3/default selection (byte-identical). Chosen general because it is no more code than a hardcoded branch, the codebase already anticipates multiple category pipelines (`question.py:29` `themed`/`kids`; the unwired `_kids.md`/`_themed.md` files), and the category signal is already threaded (`generation.py:165`). The entertainment prompt is a **fact-first variant** so it reuses the v3 facts/MCQ injection (`advanced_generator.py:695-711`) rather than forking the pipeline.

4. **Sourcing: reuse for evergreen, recency-aware Tavily for current, TMDB out.** Evergreen rides the three live sources unchanged — OpenTriviaDB already maps the five entertainment categories (`opentriviadb_source.py:20-46`), Wikipedia + Tavily cover the rest, all free/already-paid. Current/viral adds `topic=news` + `time_range=week` to the existing Tavily call (`web_search_source.py:42-47`) — verified params (research §4), no new key, no new bill (Rule #11). **TMDB rejected**: its ToS forbids commercial LLM pipelines and charging for apps that use it (research §4); movie/TV currency routes through Tavily news instead.

5. **F-3b staleness strategy = absolute phrasing + content-class TTL + the existing read-path filter + a refresh job.** Prompt forbids relative time and requires a year anchor (LLMs are temporally blind, research §5). TTL tiers: `evergreen` (no expiry) · `semi-stable` (award winners, 1–2 yr) · `current` (viral, 7–30 days), written to `expires_at`/`freshness_tag` at generation (`generation.py:213-236`). The live read-path filter **already exists** (`question_retriever.py:118,128` via `is_expired()`), so a stale "this week's #1" can never be *served*; a refresh job only *replenishes* the shrinking current tier. **Correction to research §2/§5:** they state the read-path "doesn't filter" and a partial ship would "leak stale questions" — verified stale; the filter is present and correct, so F-3b's true partial-ship risk is *degraded freshness* (the pool thins to evergreen if the scheduler lags), not incorrect serving. F-3b can therefore itself ship incrementally (news source + expiry-SET first; scheduler second) without a correctness hazard.

6. **F-3b is human-gated — for cost and infra, not for the read-path.** It introduces a **scheduler** (a new always-on moving part), commits to **recurring PAYG** (Tavily news + weekly regeneration), and is the **first code to write live `expires_at`**, which activates a previously-dormant production code path. None is correctness-risky in isolation, but together they are a spend/infra commitment that is a founder/product call (Rule #13) and needs the un-park regardless. The original "unsafe to ship without an expiry filter" rationale no longer applies (decision 5).

7. **Dormancy / reversibility — `a` for F-3a, higher-risk-within-`a` for F-3b.** F-3a is commits-only: no migration (expiry columns already exist), no schema, no deploy, no corpus writes. It changes behavior only for an order with `category == "entertainment"` or a no-category CLI/batch run that samples an entertainment topic — neither fires in production (the live worker doesn't even wire the pool, `sourcing.py:72-75`; all paid generation is PARKED). Every other order is byte-identical. F-3b stays dormant because the new news source sits behind a flag and **the read-path filter is a verified no-op while no question has `expires_at` set** (`is_expired()` returns `False` for NULL, `question.py:227-228`): it begins dropping rows only once F-3b actually generates a current-tier question, and then drops exactly the past-expiry ones. Nothing ships that alters live behavior before an explicit un-park.

## Tasks (atomic)

> Build order, each `- [ ]` independently committable, scoped small. **F-3a is Ralph-runnable** (commits-only, dormant). **F-3b is human-gated** — do not start F-3b tasks without an explicit founder go (decision 6: recurring Tavily-news PAYG + a new always-on scheduler + the first live `expires_at` write). All line refs verified Phase 4 against current `main`; no corrections needed.

### F-3a tasks (Ralph-runnable, dormant)

- [ ] **Add `prompts/question_generation_entertainment.md`.** Copy `question_generation_v3_fact_first.md` as the base so it inherits the exact placeholder contract and the `{{`/`}}` JSON brace-escaping that `PromptBuilder` (`str.format`) requires; edit only the persona/tone (pop-culture across the 4 buckets — Film · Music & Artists · TV & Streaming · Viral/Trending) and the driving-safety constraints (1–4 spoken-word answers; no visual-recognition topics e.g. "name the poster"/comics/anime; no list answers; absolute phrasing with a year anchor for any dated fact). Preserve every placeholder unchanged: `{count} {difficulty} {topics} {categories} {type} {topic_section} {avoid_section} {user_feedback_section} {escape_hatch_section} {facts_section} {excellent_examples} {ok_examples} {bad_examples_section} {mcq_patterns_section}` — these are exactly the keys `PromptBuilder.build_prompt` fills (`app/generation/prompt_builder.py:103-127`); an unknown `{placeholder}` raises `KeyError`, an unused fill key is harmless.
  - Verify: render test (mirror `tests/generation/test_prompt_response_format.py:20`, which already lists the v3 file) — `PromptBuilder(<entertainment path>).build_prompt(count=10, categories=["entertainment"], facts_section="FACT: …", mcq_patterns_section="")` returns with no `KeyError`, and the output contains the injected facts text + an entertainment-tone sentinel.

- [ ] **Load the entertainment template in `AdvancedQuestionGenerator.__init__`** alongside the existing guarded v3/open loads (`app/generation/advanced_generator.py:176-193`). Add a general `self.category_prompt_builders: dict[str, PromptBuilder]`, populated `{"entertainment": PromptBuilder(<path>)}` only when the file `os.path.exists` (same guard pattern as `v3_prompt_builder`/`open_prompt_builder`). A general map (not a hardcoded `entertainment` attribute) so kids/themed register later with no new branch (decisions 3, 2d).
  - Verify: unit test instantiates `AdvancedQuestionGenerator(...)` and asserts `"entertainment" in gen.category_prompt_builders`.

- [ ] **Add the category→builder dispatch inside the `use_fact_first` branch of `_build_batch_prompt`** (`app/generation/advanced_generator.py:686-688`). When `categories and categories[0] in self.category_prompt_builders`: set `prompt_builder = self.category_prompt_builders[categories[0]]` and `prompt_version = f"v3_fact_first_{categories[0]}"`; otherwise byte-identical to today (`self.v3_prompt_builder` / `"v3_fact_first"`). **Critical (C-b):** keep this selection *inside* the `elif use_fact_first:` block so the existing `{facts_section}` (`:695-697`), `{escape_hatch_section}` (`:702-703`), and `{mcq_patterns_section}` (`:709-711`) injection still runs unchanged for entertainment — the dispatch changes *which* builder, never *whether* facts/MCQ are injected. Both call sites (`:618` standard, `:829` structured-MCQ) inherit the dispatch automatically; no change at `:642`/`:848`.
  - Verify: unit test on `_build_batch_prompt` with `categories=["entertainment"]`, truthy `source_facts`, `mcq_patterns={…}` → returns `use_fact_first is True`, `prompt_version == "v3_fact_first_entertainment"`, and the rendered prompt contains (a) the entertainment sentinel, (b) the formatted facts section, (c) the mcq_patterns_section text.

- [ ] **Add dormancy / fall-through regression tests** for `_build_batch_prompt` proving every non-entertainment path is byte-identical to today and the no-facts entertainment case falls back cleanly.
  - Verify: (a) `categories=["history"]` + facts → `prompt_version == "v3_fact_first"`, no entertainment sentinel; (b) `categories=["entertainment"]` + `source_facts=None` → `use_fact_first is False`, builder is `self.prompt_builder`, `prompt_version == self.prompt_version`, no entertainment sentinel, no exception (documents the chosen **no-facts behavior: clean fall-back to the generic prompt** — entertainment is a fact-first-only variant, no separate fact-less entertainment prompt, per Rule #1); (c) `open_shape=True` + `categories=["entertainment"]` → `use_open` precedence intact (`prompt_version == "open"`).

- [ ] **End-to-end dispatch + category-stamping test through `generate_questions`** (generation LLM mocked). An order with `categories=["entertainment"]` and fake `source_facts` → every returned question has `generation_metadata.prompt_version == "v3_fact_first_entertainment"` and `category == "entertainment"` (the latter from `default_category=categories[0]`, `:642`). This is the F-3a "small dry-run validation"; the paid corpus dry-run waits for un-park (parked, out of scope).
  - Verify: pytest integration test with the generation LLM mocked to return a fixed batch; assert prompt_version + category on each question.

### F-3b tasks (human-gated)

> Gate (decision 6): F-3b commits to recurring Tavily-news PAYG + a weekly regeneration scheduler (a new always-on moving part) and writes the **first live `expires_at`**, which activates the dormant read-path filter. None is correctness-risky in isolation (the read-path filter already exists and is correct — decision 5), but together they are a spend/infra commitment that is a founder call and needs the un-park regardless. Tasks 1–4 are individually low-risk and side-effect-free until generation runs; task 5 is the gated heart.

- [ ] **Recency-aware Tavily news sourcing.** Add `topic="news"` + `time_range="week"` (valid Tavily params, research §4) to the `self.client.search(...)` call (`app/sourcing/web_search_source.py:42-47`), behind a flag or a thin `NewsWebSearchSource` subclass, default off (dormant). Replaces the deleted `news_source.py` path; no new key/bill (Rule #11).
  - Verify: unit test with a mocked `AsyncTavilyClient` asserts the `search(...)` kwargs include `topic="news", time_range="week"` when recency is requested, and contain neither param on the default path.

- [ ] **Stamp `expires_at` + `freshness_tag` by content-class** in `GenerationStage`'s per-question loop (`app/orchestrator/stages/generation.py:213-236`, where `prompt_seed`/`language`/provenance are already set; nothing sets expiry today). Tiers (decision 5): `evergreen` → `expires_at=None`; `semi-stable` → now + 1–2 yr; `current` → now + 7–30 days. The stamped fields ride `question_to_row` (`app/db/models/question.py:184-185`, verified present) → PersistStage → `PgvectorQuestionStore.add` unchanged. **No new DB column / no migration** — reuse the existing `expires_at`/`freshness_tag` columns.
  - Verify: unit test on the loop — a `current`-class question gets `expires_at ≈ now + N days` + a non-null `freshness_tag`; an `evergreen` question gets `expires_at is None`.
  - Open design point (resolve at greenlight): the **content-class carrier** — order-level (one TTL tier per `current` order, mirrors how `category` flows) vs per-question (read from the prompt's `content_class`, task below). Order-level is simpler; per-question matches decision 5's "award winners = semi-stable, viral = current" granularity. Decide at greenlight; no DB column either way.

- [ ] **Entertainment prompt: absolute-phrasing enforcement + `content_class` signal.** Extend `question_generation_entertainment.md` (from F-3a) so current/dated questions must carry a year anchor and never relative time ("current/latest/this year" — LLMs are temporally blind, research §5), and emit a `content_class` (`evergreen`/`semi-stable`/`current`) the stamping loop consumes. Carry `content_class` through the existing `tags`/`freshness_tag` channel — no new schema.
  - Verify: render test that the prompt carries the absolute-phrasing instruction + the `content_class` field in its response format; a parse test that a returned `content_class` survives to the stamping loop.

- [ ] **Read-path filter activation test** (correctness guard for the dormancy claim; side-effect-free, safe to land independent of the cost/scheduler gate). In `apps/quiz-agent`, test `QuestionRetriever` against the existing in-memory filter (`app/retrieval/question_retriever.py:118` primary + `:128` fallback) via `Question.is_expired()` (`packages/shared/quiz_shared/models/question.py:225-235`).
  - Verify: (a) all candidates `expires_at=None` → **zero dropped**; (b) one candidate with a past `expires_at` → that one dropped, rest retained; (c) a future `expires_at` candidate → retained. Proves the filter is a no-op until F-3b sets expiry, then drops exactly the past-expiry rows (decisions 5, 7).

- [ ] **Scheduled refresh/regenerate job for the `current` tier** — the one genuinely new moving part; replaces the dead `scripts/expire_questions.py` (imports the removed `apps/question-generator`, targets frozen ChromaDB). Periodically regenerates current-tier entertainment to replenish the tier as rows pass `expires_at`. **This is the human-gated heart** (recurring-PAYG + always-on-scheduler + first-live-`expires_at`-write commitment).
  - Verify: run once against a seeded DB with current-tier rows near expiry → fresh current-tier rows added (with new `expires_at`); idempotent on re-run.
  - Open design point (resolve at greenlight): the **scheduler mechanism** (e.g. arq cron inside quiz-pack-api vs external cron) and the refresh cadence/budget cap — a founder/infra call (decision 6).

## Acceptance

### F-3a acceptance (Ralph-verifiable, dormant)

- A `_build_batch_prompt` call with `categories=["entertainment"]` and truthy `source_facts` returns `use_fact_first is True` and `prompt_version == "v3_fact_first_entertainment"`, and the rendered prompt contains the entertainment sentinel, the formatted source-facts section, and the mcq_patterns_section text (proves the dispatch rides the fact-first branch with injection preserved — C-b).
- A `generate_questions` order with `categories=["entertainment"]` + facts (LLM mocked) yields questions whose every `category == "entertainment"` and `generation_metadata.prompt_version == "v3_fact_first_entertainment"`.
- **Dormancy:** for `categories=["history"]` + facts, `prompt_version == "v3_fact_first"` and the rendered prompt is unchanged from `main` (no entertainment text); for `open_shape=True`, `prompt_version == "open"`. No order without `category == "entertainment"` changes output.
- **No-facts fallback:** `categories=["entertainment"]` + `source_facts=None` → `use_fact_first is False`, builder is `self.prompt_builder`, `prompt_version == self.prompt_version`, no entertainment text, no exception.
- `prompts/question_generation_entertainment.md` renders via `PromptBuilder.build_prompt(...)` with no `KeyError` (placeholder parity with the fill set in `prompt_builder.py:103-127`).
- `cd apps/quiz-pack-api && pytest tests/ -v` green; no new migration, no schema change, and no file touched outside `apps/quiz-pack-api/{prompts,app/generation,tests}`.

### F-3b acceptance (human-gated)

- With recency requested, the Tavily `search(...)` call is invoked with `topic="news"` and `time_range="week"`; on the default path neither param is present (mocked-client assertion).
- The stamping loop sets `expires_at is None` for an `evergreen` question and `expires_at ≈ now + days` (with a non-null `freshness_tag`) for a `current` question; these survive `question_to_row` (`db/models/question.py:184-185`) onto the persisted row with no migration.
- **Read-path filter:** with no question carrying `expires_at`, `QuestionRetriever` drops **zero** candidates; with one past-`expires_at` candidate present, it is dropped and the rest retained; a future-`expires_at` candidate is retained (`question_retriever.py:118,128` via `is_expired()`).
- The entertainment prompt forbids relative-time phrasing and emits a `content_class`; a generated current question carries an absolute year anchor and a `content_class` that maps to a non-null `expires_at`.
- The refresh job, run against a seeded near-expiry current-tier corpus, adds fresh current-tier rows with new `expires_at` and is idempotent on re-run.
- Both the quiz-pack-api and quiz-agent suites green; the news source stays dormant (flag off) and live serving behavior is unchanged until the first current-tier question is generated.

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done (prior session — research doc) | — |
| 2 · Plan              | ✅ done | scope + 7 decisions; top-level VERIFIED read-path filter EXISTS (corrects research §2/§5) |
| 3 · Plan review       | ✅ done | ready-check **READY** (0 blockers) · design-soundness **SOUND 0.86** (0 flaws, 2 cautions) |
| 4 · Impl-plan         | ✅ done | C-a resolved; F-3a (5 tasks) + F-3b (5 tasks) + machine-evaluable Acceptance, both split; C-b handled; line refs verified vs `main` |
| 5 · Impl-plan review  | ✅ done | ready-check **READY** (0 blockers) · design-soundness **SOUND 0.87** (0 flaws, 2 cautions) |
| 6 · Split             | ✅ done | tasks already atomic + ready-check-confirmed; single-session F-3a → **no separate execution-prompts.md** (the `## Tasks` block is the exec guide); Triage set |

**Last updated:** 2026-06-29 (next session) · **PREP COMPLETE** — F-3a `ready-for-agent`, F-3b `ready-for-human`. · **Gate attempts:** P3 1/3 ✅ · P5 1/3 ✅

### Phase 5 review — cautions (both accepted, non-blocking)
- **PC-1 (S1/S5, accepted limitation):** the no-facts fall-back routes a fact-less `entertainment` order to the generic v3 prompt, which lacks the entertainment-only driving-safety rules (no visual-recognition / no list answers). **Accepted, not fixed (Rule #1):** the path is rare (entertainment is fact-first sourced from OTDB/Wikipedia/Tavily, which reliably yield facts), parked until un-park, provenance-traceable (`prompt_version` stays `v3_fact_first`), and the global 10-word brevity backstop (`_violates_answer_brevity`) still fires. Building a separate fact-less entertainment prompt would be scope creep. Surfaced here so it is not silent.
- **PC-2 (S1/S3, deferred by design):** F-3b's expiry-stamping task leaves the content-class carrier (order-level vs per-question) open; per-question couples it to the prompt task. This is a legitimate greenlight-time decision for a human-gated phase — F-3b is not auto-runnable, so the coupling never blocks Ralph.

### Phase 3 review — cautions to carry into Phase 4
- **C-a (product) — ✅ RESOLVED (founder, option-2):** entertainment tone everywhere, delivered via **explicit `category="entertainment"` generation → DB → surprise-me serving**, not via the topic pool. Verified first-hand: no-category generation is one mixed batch under `categories=None`→`"general"` and pool strings never reach `_build_batch_prompt`, so the **~10 topic-pool entries are dropped from F-3a**. Full resolution + evidence in `## Scope` (F-3a → C-a resolved block) and interaction (b).
- **C-b (impl detail) — ✅ HANDLED in Phase 4:** the entertainment prompt rides the `use_fact_first` branch (`advanced_generator.py:680-682,695`); the dispatch is placed **inside** that branch so `{facts_section}`/`{mcq_patterns_section}` injection is preserved, with an explicit no-facts clean fall-back to the generic prompt (see F-3a tasks 3–4).
