# Issue #69 — Cost: translation runtime cache (3.5× SK serving cost)

**Triage:** enhancement · ✅ SHIPPED (durable on-disk store implemented 2026-07-06; v1 in-memory `e27d562`)

> **In-memory cache v1 shipped** (`e27d562`, 2026-06-29). **Durable follow-up re-prepped 2026-06-30:**
> the founder wants the translation store to **survive restarts/redeploys** plus a **refresh mechanism**
> for stale/edited source questions. All 6 `/prepare-issue` phases passed (both dual gates green, Phase-5
> caught + fixed a real runtime-write fail-soft flaw) — ready for an autonomous (Ralph) run.

**Created:** 2026-06-21 · **Founder:** Michal · **Source:** #64 full-project review (rank 19 — verified first-hand)

**Severity:** medium — the founder's device always runs Slovak, so every test session pays the penalty.

**Reversibility:** a (reconfirmed by both dual gates) — persists to the **existing `/data` Fly volume**
via a local **SQLite** store (the `ratings.db` pattern: sync `create_engine` + `create_all` auto-schema),
so **no Alembic migration, no prod DDL, no cross-app DB coupling**. App-layer + a data file on an
existing volume. Reversible by removing the store.

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done | Durable recon verified first-hand; store LOCKED = SQLite-on-`/data` (`ratings.db` pattern: sync write from async, microsecond, no new dep), version-stamp = `TRANSLATION_PROMPT_VERSION`, class **a** reconfirmed (auto-`create_all`, no Alembic/DDL/cross-app). **Next: Phase 2.** |
| 2 · Plan              | ✅ done | Re-planned against locked durable scope: warm-load + write-through topology, version-stamp lazy-invalidation, fail-soft startup, idempotent `INSERT OR REPLACE` (no lock), one auto-`create_all` table. **Next: Phase 3.** |
| 3 · Plan review       | ✅ done | ready-check **READY** (no blockers) · design-soundness **SOUND 0.82** — 3 caution findings (fail-soft is net-new not inherited; upsert needs SQLite-dialect insert; global version-stamp couples both prompts) all **folded into Resolved design decisions**. **Next: Phase 4.** |
| 4 · Impl-plan         | ✅ done | **1 atomic task** (impl + tests, one commit — split rejected, thin seam) + **9 machine-evaluable acceptance criteria** written. Locked: dedicated `TranslationStore` class (mirrors `SQLClient`, own `declarative_base`) in new `app/translation/store.py`; env var `TRANSLATION_CACHE_URL`; fail-soft guard wrapping all 3 init steps in `TranslationService.__init__`; SQLite-dialect `on_conflict_do_update` upsert; `_maybe_store` as single write-through point. **Next: Phase 5.** |
| 5 · Impl-plan review  | ✅ done | **Cycle 1:** READY · **UNSOUND 0.60** (runtime durable write unguarded inside translate `try/except`). **Fixed** (dict-insert-first + best-effort swallowing guard; +2 tests). **Cycle 2:** ready-check **READY** (no blockers) · design-soundness **SOUND 0.87** (no flaws; lone caution = within-process write not retried, accepted cache-aside tradeoff, noted in plan). **Next: Phase 6.** |
| 6 · Split             | ✅ done | **1 atomic task confirmed** (impl + tests, one commit — independently-committable, self-contained for a fresh Ralph agent: names exact files/symbols/line-anchors + the dialect-upsert idiom + fail-soft rationale; Acceptance gives the exact pytest run + 11 named machine-evaluable tests = the objective `Done =` check). Split NOT demanded — thin seam, every criterion is a `TranslationService` integration assertion. **Class a reconfirmed:** own `declarative_base` + `create_all` (no Alembic, no prod DDL), no quiz-pack-api files, `main.py` untouched — no class-b surface hides in the task. **Single-session → NO `issue-69-execution-prompts.md`** (≈40-line store + ≈15-line wiring + ≈120-line tests, one context, one pytest run). |

**Last updated:** 2026-06-30 · **Status:** ✅ **PREP COMPLETE — ready-for-agent** · all 6 phases ✅ (P3 READY+SOUND 0.82 · P5 cycle-2 READY+SOUND 0.87 · P6: 1 atomic task, class **a**, no execution-prompts file) · v1 in-memory cache shipped (`e27d562`); durable store builds on it. **Gate attempts:** P3 1/3 (passed) · P5 2/3 (cycle 1 failed→fixed, cycle 2 passed).

**Locked scope decision (founder, 2026-06-30 — supersedes 2026-06-29):** a **durable, lazy-filled
translation store**, persisted to the **existing `/data` Fly volume** (reuse the `ratings.db` /
`TTSCache` on-disk pattern — survives restarts & redeploys, **no new infra, no migration, no
quiz-pack-api coupling**). Behaviour stays cache-like (miss → translate → persist; errors/fallbacks
**never** stored), but durable. **Fill = lazy** (translate on first encounter, persist; the finite
corpus warms over one play-through, then ~zero serving cost) — **not** an offline batch pre-translation
pass (deferred as a future step-up). **Invalidation/refresh:** key by exact
`(kind, source_text, target_language)` so an **edited source question is self-invalidating** (changed
text → new key → fresh translation; the old row is orphaned, never served); a **translation version
stamp** (prompt/model rev) is the manual refresh lever to re-translate unchanged questions after a
prompt/model improvement; orphan cleanup is optional (tiny data). SK-focused; the key generalizes to
CS for free.

> **Prior locked decision (2026-06-29, superseded):** runtime *in-memory* instance cache only, no
> durability — chosen for class-a minimalism. Overturned because it re-warms (re-pays cost) on every
> redeploy and offers no refresh lever; durability is cheap given the pre-existing `/data` volume.

## Why

Translation makes a fresh `gpt-4o-mini` call per question/feedback with **no caching** — ~2 LLM
translate calls per answered cycle. Issue #49 measured SK sessions at `$0.00231` vs `$0.000657`
for EN — a **~3.5× multiplier**, entirely from translation — and the founder's device always runs
Slovak, so every test session pays it. The ~580-question approved corpus is **finite**, so the same
questions recur; caching validated translations removes almost all of the repeat cost.

The v1 in-memory cache (`e27d562`) already captures the within-process repeats, but it is wiped on
every Fly redeploy and re-warms (re-pays the full translation cost) per process — and it offers no
lever to re-translate questions after a prompt/model improvement. This follow-up closes that gap by
making the store **durable across restarts and redeploys**, persisted to the **existing `/data` Fly
volume**, with a **version stamp** as the manual refresh lever. Durable-zero-cost after the corpus
warms once, not zero-cost-per-process.

## Scope

**In scope**
- A **durable translation store**: local SQLite on the existing `/data` Fly volume, adopting the
  `ratings.db` pattern (sync `create_engine` + `Base.metadata.create_all` auto-schema, no Alembic,
  no prod DDL, no quiz-pack-api coupling). Store path = env var, default
  `sqlite:///./data/translations.db` (→ `/data` in prod via the mount). One table, PK
  `(kind, source_text, target_language, version)`.
- **Warm-load + write-through** topology layered on the v1 in-memory cache: at startup, warm
  `self._cache` from rows matching the current `TRANSLATION_PROMPT_VERSION`; on each validated
  success, write through to **both** the dict and SQLite (`INSERT OR REPLACE`). Reads stay
  in-memory; restarts reload from disk.
- A **version stamp** (`TRANSLATION_PROMPT_VERSION` module constant) baked into key + row as the
  manual refresh lever.
- Both async methods (`translate_question`, `translate_feedback`), reusing the v1 hook points
  (lookup/store **after** each short-circuit; store **only on validated success**).
- Tests: a `tmp_path` store URL (never touch `/data`) + a **durability proof** (a second
  `TranslationService` on the same on-disk path serves from disk with no new LLM call) + a
  version-bump test.

**Out of scope / deferred**
- **Offline batch pre-translation** of the approved corpus — deferred; when wanted it just
  bulk-fills the **same** SQLite table, zero rework (the lazy fill already warms the corpus over one
  play-through).
- **Orphan / old-version pruning** — old-version rows are simply ignored (never served); a one-line
  `DELETE WHERE version != current` sweep is optional and not built now (data is tiny).
- A translated `questions` DB column / Alembic migration (would flip #69 to **class b /
  ready-for-human** and cross-app-couple DDL) — explicitly rejected; the durable SQLite store on
  `/data` stays **class a**.
- **CS corpus pass** — the key already carries `target_language`, so it generalizes to CS for free;
  no CS-specific work in this issue.

## Resolved design decisions

> Durable store, building **on** the shipped v1 in-memory cache (`e27d562`) — it changes *where the
> value durably lives*, not *when* it is read/written. The v1 placement (lookup/store after the
> short-circuit), the validated-success-only discipline, and the `kind` discriminator all carry over
> unchanged.

1. **In-memory ↔ durable topology — warm-load + write-through.** Reads stay in the in-memory
   `self._cache` dict (fast, no per-lookup disk hit). **Warm-load:** when the `TranslationService`
   singleton is constructed at startup (`main.py:230`, its `__init__` — the one place the store is
   opened), it loads every SQLite row whose `version` matches the current `TRANSLATION_PROMPT_VERSION`
   into `self._cache`. **Write-through:** on each validated success, write to **both** the dict and
   SQLite via `INSERT OR REPLACE`. On restart/redeploy the warm-load repopulates the dict from disk →
   durable. The store is opened once on the singleton (not per request), matching `ratings.db`'s
   single `SQLClient` at `main.py:203-207`.
- **Fail-soft startup — net-new explicit guard, NOT inherited (Phase-3 Gate B, verified first-hand).**
  A missing, empty, or corrupt DB file must degrade to an **empty in-memory cache that re-warms
  lazily** — startup never crashes on it. ⚠️ **This is the one thing Phase 4 must not take on faith:**
  the `ratings.db` precedent does **not** grant it. `SQLClient.__init__` wraps `create_engine` +
  `create_all` in **no** try/except (`sql_client.py:84-85`) and its caller re-raises
  (`main.py:209-211`); and `TranslationService()` is constructed (`main.py:230`) **inside the services
  block that ends in `except Exception: … raise` (`main.py:324-326`)** — so any exception from
  engine-open, `create_all`, or the warm-load `SELECT` would propagate and **crash-loop the whole
  quiz-agent app** on a bad `/data/translations.db`. Fail-soft is therefore **explicit, first-class
  error handling the store must add itself**: wrap all three init steps (open + `create_all` +
  warm-load) in a `try/except` that logs and falls back to an empty dict. It is *analogous* to the
  per-call translate fallback (`translator.py:160`/`:213`) but lives at a **different layer**
  (store-open, not per-translate) and must be its own tested guard. **Fail-soft also covers the
  *runtime* durable write (Phase-5 Gate B):** the write-through `upsert` in `_maybe_store` is itself
  best-effort — wrapped in a swallowing `try/except` and sequenced **after** the in-memory dict insert —
  so a disk-write hiccup (full/read-only/locked `/data`) never propagates into the translate
  `try/except` (which would otherwise serve untranslated English and skip caching). See the
  `_maybe_store` task + `test_runtime_write_failure_still_serves_translation`.
2. **Version-stamp semantics — lazy re-translate, old rows orphaned.** `(kind, source_text,
   target_language, version)` is the full key. **Bumping `TRANSLATION_PROMPT_VERSION`** (after a
   prompt/model improvement) means unchanged-text rows from the old version no longer match the
   lookup → each is lazily re-translated on next encounter and written as a **new row** under the new
   version; the warm-load only loads current-version rows, so old rows are never served. **Edited
   source text self-invalidates** the same way — new text = new key = fresh translation, old row
   orphaned. Old-version rows are simply **ignored**, not pruned; an optional `DELETE WHERE
   version != current` sweep is low-priority and not built now (data is tiny). **One global
   `TRANSLATION_PROMPT_VERSION` (accepted, Phase-3 Gate B):** it covers both prompts, so bumping it to
   refine only one method's prompt also orphans+re-warms the other `kind`'s rows. Accepted as-is —
   the cost is one extra lazy re-warm over a ~1160-row corpus, negligible. A per-`kind` version would
   be strictly cheaper *if* the two prompts' revisions ever diverge; deferred until that happens.
3. **Errors / fallbacks never persisted (invariant preserved from v1).** Validation-fail and `except`
   fallbacks (the return-original paths) are written to **neither** SQLite **nor** the dict. A
   transient LLM/validation error must not poison the durable store — durability does **not** weaken
   the v1 poisoning guard. Lookup/store stay **after** each method's short-circuit (`source==target`
   / `target=="en"`), so no-op passthroughs are never persisted either.
4. **Bounding.** The in-memory dict keeps the existing `CACHE_MAX_ENTRIES` soft guard (stop inserting
   past the cap, still serve hits). SQLite is effectively unbounded but **tiny** — recon
   (`serializers.py:43`) confirms **only question text + correct-answer feedback are translated**
   (options/distractors are not), so realistic SK-only cardinality is ~1160 short rows (≤~1740 even
   with slack), a sub-megabyte file. That is fine as-is; orphan/old-version cleanup is optional, not
   built now.
5. **Concurrency / stampede — accepted non-issue, no lock.** The check-then-translate-then-store is
   intentionally unsynchronized: two simultaneous identical requests could both miss and both
   translate (one wasted call, never incorrectness) — and the founder's use is sequential/single-user.
   Additionally, SQLite `INSERT OR REPLACE` is **idempotent**, so a duplicate concurrent write is
   harmless (the second simply overwrites identical content). No `asyncio.Lock` needed;
   concurrency-safety is **not** an acceptance criterion.
6. **Schema — one auto-created table.** Columns `(kind, source_text, target_language, version,
   translated_text)`, primary key `(kind, source_text, target_language, version)`, with
   `kind ∈ {"question", "feedback"}` (the two methods use **different prompts**, so `kind` prevents a
   cross-method collision on identical text). Created via `Base.metadata.create_all` at store init —
   **not** an Alembic migration, exactly the un-migrated `ratings.db` precedent that already runs in
   prod. No new dependency (SQLAlchemy/SQLite already present), no DDL apply, no cross-app coupling →
   stays **class a**. **Upsert mechanism (Phase-3 Gate B — not free, not the `ratings.db` idiom):**
   `ratings.db` is **append-only** (`session.add` with a fresh-UUID PK, `sql_client.py:104-118`), so
   the write-through can't copy `add_rating`. The composite-PK upsert needs the SQLite-dialect insert —
   `sqlalchemy.dialects.sqlite.insert(...).on_conflict_do_update(...)` (or `.prefix_with("OR REPLACE")`,
   or raw SQL). The intent (idempotent upsert keyed on the four-column PK) is sound; Phase 4 must use
   the dialect insert, not the ORM `add` idiom.

- **Second-order fit (D11), without over-building.** Two future step-ups land with **zero rework**:
  (a) the deferred **offline batch pre-translation** just bulk-fills the **same** `translations`
  table — the durable lazy fill and a batch pre-fill are the same rows; (b) **CS** (or any language)
  is already covered because the key carries `target_language`. Neither is built now. The store is a
  thin durable layer behind the existing client call — simple **and** robust, no speculative
  abstraction.

## Evidence (verified first-hand 2026-06-21)

- `apps/quiz-agent/app/translation/translator.py` — no `@lru_cache`, no instance cache.
- `apps/quiz-agent/app/quiz/flow.py:146,178,280-283` — translate calls per question cycle (feedback ×2 + next-question text ×1).
- Cross-ref: `docs/artifacts/daily-limit-cost-model.html` / #49 ($0.00231 SK vs $0.000657 EN).
- (The `fly_client_ip` rate-limiter default fix that the review bundled here is owned by **#65** to avoid a split fix — not duplicated.)

## Research (Phase 1)

*Web pass: NOT run (both v1 and durable re-prep) — this is an internal persistence problem with no open external unknown. The durable store choice (SQLite-on-`/data` vs JSON/file) is settled entirely by in-repo precedent (`ratings.db` vs `TTSCache`, both already on the mounted volume); no maintained-library check could change it. The only library question (cachetools vs stdlib) was already settled by in-repo evidence (cachetools absent + async-method constraint).*

> **Durable re-prep (2026-06-30):** the v1 Strand A/B below documented the **in-memory** cache and remains accurate for what shipped (`e27d562`). The two subsections marked **"durable re-prep"** add the persistence recon for the revised scope — they supersede the v1 *storage* conclusion (instance dict → durable on-disk store) but leave the v1 *placement/short-circuit/validated-success-only* findings intact, since the durable store reuses exactly those hook points.

### Strand A — Code recon (verified first-hand 2026-06-29)

- **"No cache" confirmed.** `translator.py` `TranslationService` has no `@lru_cache`/instance cache. Two public **async** methods: `translate_question(question, target_language, source_language="en")` (`translator.py:81`, prompt + `max_tokens=300`) and `translate_feedback(feedback, target_language)` (`translator.py:140`, `max_tokens=50`). Both call `self.client.chat.completions.create(...)` (async OpenAI from `llm_factory.openai_client(async_=True)`, `translator.py:41`). Both short-circuit when `source==target` / `target=="en"`.
- **Lifecycle = process singleton (KEY for the cache).** Built once at startup `main.py:230` (lifespan), held as module global `main.py:89` + `app.state.translation_service` `main.py:372`, injected everywhere via `get_translation_service → request.app.state.translation_service` (`api/deps.py:378`). → an **instance-level cache survives across all requests/sessions for the process lifetime** — satisfies the "persists across a session, not per-request" criterion with **no extra plumbing**.
- **Call-sites verified** (`flow.py`): `:146` (answer branch) and `:175` (skip branch) both → `_translate_correct_answer` → `translate_feedback`; `:280-283` → `question_to_dict_translated` → `translate_question` (`serializers.py:54`). Per **answered** cycle = **2 distinct LLM translate calls** (1 feedback correct-answer + 1 next-question), not 3 — answer/skip are mutually exclusive branches. (Issue's "feedback ×2 + next ×1 = 3" over-counts, or folds in the initial-question fetch at `quiz.py:151` / `tts.py:82`; immaterial to design.) Shapes: long question text via `translate_question` vs short answer string via `translate_feedback` — **different methods/prompts**, so the cache key should include a `kind` discriminator to avoid a cross-method collision.
- **Corpus store + head migration.** Approved corpus = Postgres **`questions` table (pgvector)**; schema = SQLAlchemy `questions_table` (`packages/shared/quiz_shared/database/pgvector_client.py:60-92`); served read-only on the hot path by `PgvectorQuestionStore` via `QuestionRetriever`. **DDL is owned by quiz-pack-api Alembic** — migration `1c5e0fa7b3d4_core_entities` (`op.create_table("questions", …)`). **Head = `1c5e0fa7b3d4`** (→ baseline `29f509ffa769`). quiz-agent's own alembic (`0001-0004`) owns only auth/usage tables (#60), **not** the corpus. **No translation column exists anywhere.**
- **Test idiom** (`tests/test_translation_validation.py`): fixture builds `TranslationService()` under `patch.dict(os.environ, {"OPENAI_API_KEY": "sk-test-dummy"})`; tests replace `service.client.chat.completions.create = AsyncMock(return_value=<MagicMock with .choices[0].message.content>)` (`:122`, helper `_mock_openai_response` `:109`) and drive via `asyncio.run(...)`. A cache test follows this exactly: set the AsyncMock, call the method twice with the same `(text, lang)`, assert `service.client.chat.completions.create.call_count == 1` and that both results are equal.

### Strand A — Durable persistence recon (durable re-prep, verified first-hand 2026-06-30)

- **`/data` volume confirmed.** `apps/quiz-agent/fly.toml:36-38`: `[[mounts]] source = "quiz_agent_data" → destination = "/data"`. Two stores already persist here, both via paths defaulting under `./data` → mounted at `/data` in prod.
- **Precedent 1 — `ratings.db` (THE pattern to adopt).** Wired at `main.py:203-207`: `SQLClient(database_url=os.getenv("RATINGS_DATABASE_URL", "sqlite:///./data/ratings.db"))`. `SQLClient` (`packages/shared/quiz_shared/database/sql_client.py:70-90`) uses **sync** SQLAlchemy: `create_engine` + sync `sessionmaker`, schema auto-created by **`Base.metadata.create_all(self.engine)` at init — NOT Alembic** (key for the class confirmation). Its writes are **synchronous** (`add_rating`: `session.add`+`session.commit`+`session.close`, `:117-119`) and are called **directly as a bare blocking call from an async path** — `FeedbackService.submit_rating` is `async def` (`rating/feedback.py:44`) and invokes `self.sql.add_rating(...)` un-awaited, un-executor-wrapped at `rating/feedback.py:94`. → **The repo idiom for "write to on-disk SQLite from an async method" is a direct sync call; a single-row SQLite write is microsecond-fast and does not meaningfully block the loop.** This is the crux: the translation store can do exactly this — no `run_in_executor`, no `aiosqlite`.
- **Precedent 2 — `TTSCache` (the JSON/file alternative, weaker here).** `tts/cache.py`: file store at `./data/tts_cache` (`static/`, `questions/`, `metadata.json`). Write strategy = `path.write_bytes()` for the blob + `_save_metadata()` which **rewrites the ENTIRE `metadata.json` on every `set()`** (`json.dump(data, f)`, `:104-105`), O(n) per write. **No concurrency handling** (no lock, no atomic-rename temp file). Sync methods used as a sync object. → A full-file JSON rewrite per cache miss is wasteful and non-transactional for a growing K/V; documented here only to be rejected in Strand B.
- **TranslationService singleton + hook points re-confirmed against CURRENT `translator.py` (post-`e27d562`).** Built once `main.py:230`, module-global `main.py:89`, on `app.state` `main.py:372`, injected via `get_translation_service → request.app.state.translation_service` (`api/deps.py:378-379`). Two async methods unchanged: `translate_question` (`:99`, short-circuit `source==target` `:113`, lookup `:116-119`, validated-success store `_maybe_store(...)` `:157`) and `translate_feedback` (`:164`, short-circuit `target=="en"` `:175`, lookup `:178-181`, store `:210`). The v1 in-memory `self._cache` (`:50`) + `_maybe_store` (`:52-60`, reads module-global `CACHE_MAX_ENTRIES` at call-time) and the **store-only-on-validated-success** discipline (fallbacks at `:156`/`:162`/`:215` never stored) are the **exact hook points the durable store reuses** — the durable layer swaps *where* the value lives (on-disk row vs in-memory dict entry), not *when* it is read/written.
- **Call sites still valid** (no re-document): `flow.py:146,175` → `_translate_correct_answer` (`:352`) → `translate_feedback` (`:357`); `flow.py:280` → `question_to_dict_translated` (**`app/serializers.py:43`**, not `app/quiz/serializers.py`) → `translate_question` (`serializers.py:54`).
- **Durable test idiom (extends v1).** Same AsyncMock-on-`client.chat.completions.create` + `asyncio.run` + `call_count` pattern (see `tests/test_translation_cache.py`). Two durable-specific additions: (a) **point the store at a `tmp_path` URL** (e.g. `sqlite:///{tmp_path}/translations.db`) so tests never touch `/data`; (b) **the durability proof** — after a first translate persists, construct a **SECOND `TranslationService` pointed at the same on-disk path**, call the same `(kind, text, lang)`, and assert it serves from disk (no new LLM call: `call_count` does not increase across the instance boundary). A version-bump test asserts that bumping `TRANSLATION_PROMPT_VERSION` forces a re-translate of an existing-text row.

### Strand B — Build-vs-adopt (D10)

- **Runtime cache → BUILD a plain instance dict.** In-repo idiom: `functools.lru_cache(maxsize=1)` only on *sync* singleton getters (`quiz-pack-api config.py:47`, `deps.py:33`); `cachetools` is **not** a dependency anywhere; TTS uses a bespoke disk-backed `TTSCache` (heavier than needed). `functools.lru_cache` **cannot** wrap async methods (caches the coroutine; keys on `self`). Cardinality ≈ 580×3 ≈ 1740 < 2000 cap → eviction rarely fires, so a sophisticated LRU policy buys little. → `self._cache: dict[(kind, text, lang) → str]` on the singleton, simple size guard at ~2000, and **cache only validated successes** (don't cache the fallback-to-original, so a transient LLM error isn't poisoned). No new dependency, async-safe, matches the repo's minimal-deps bias. (`cachetools.LRUCache` is the only real alternative if true LRU eviction is wanted — not worth a new dep for a cap that is essentially never hit.)
- **Offline corpus pre-translation → JSON sidecar; AVOID the DB column.**
  - **JSON sidecar** (committed file mapping question id/text → `{sk, cs}`): **no migration**, no schema/prod-DB change → keeps the issue **class a (ready-for-agent)**.
  - **Translated `questions` column** (e.g. `translations JSONB`): requires an **Alembic migration in quiz-pack-api** (head `1c5e0fa7b3d4` → new revision) **+ a prod DB apply** → flips the issue to **class b (ready-for-human)**; also cross-app couples DDL (quiz-pack-api) with serving (quiz-agent).
  - **Verdict:** runtime instance cache + (optional) JSON sidecar. The DB column is the **only** option that needs a migration → not recommended for this issue.

### Strand B — Durable store: build-vs-adopt LOCKED (durable re-prep, 2026-06-30)

**The one real decision — which on-disk store: SQLite-on-`/data` (like `ratings.db`) vs a JSON/file store (like `TTSCache`)?**

- **LOCKED: SQLite-on-`/data`, the `ratings.db` pattern.** Adopt the proven in-repo precedent (sync SQLAlchemy `create_engine` + `Base.metadata.create_all` auto-schema, default URL under `/data`), as a small dedicated translations store/table. Concrete reasons, each grounded in recon:
  1. **Async-write without blocking is already solved by this exact pattern.** `ratings.db` writes a single row synchronously (`add_rating`, microsecond `INSERT`/`commit`) called directly from an `async def` (`feedback.py:94`) with no executor and no `aiosqlite`. The translation store does the same — a synchronous single-row `INSERT OR REPLACE` from inside the async translate methods. **No new dependency, no event-loop blocking, no thread offload.**
  2. **JSON (TTSCache) is strictly worse for this shape.** TTSCache rewrites the whole `metadata.json` on every `set()` (O(n), `:104-105`) and is not concurrency-safe; for a growing K/V of ~1160–1740 rows that is wasteful and non-transactional. SQLite gives transactional single-row writes for free.
  3. **The refresh lever + orphan-sweep want SQL.** A `version` column and an optional orphan cleanup are a `WHERE … AND version = ?` lookup and a one-line `DELETE WHERE version != ?` — trivial in SQLite, manual dict surgery in JSON.
  4. **Minimal-deps + repo idiom.** SQLAlchemy/SQLite is already a dependency and a blessed pattern (`backend.md`: "SQLite: Ratings and persistent data"). Zero new deps; matches the founder's locked "reuse the `ratings.db`/`TTSCache` on-disk pattern".
- **Store-path config (decided).** Mirror `main.py:204-205`: an env var (e.g. `TRANSLATION_CACHE_URL`) with default `sqlite:///./data/translations.db` (→ `/data` in prod via the mount); tests inject a `tmp_path` URL. A separate DB file from `ratings.db` keeps the corpus-translation data isolated and avoids touching the ratings schema. (Whether it's its own `SQLClient`-style class or a thin engine on a single `translations` table is a Phase-4 implementation detail; the store *technology* is what's locked here.)
- **Version-stamp mechanism (decided).** A module constant `TRANSLATION_PROMPT_VERSION` (string/int) baked into the key **and** the row, alongside `(kind, source_text, target_language)`. Lookup matches on all four; the stored row carries the version. Bumping the constant after a prompt/model improvement makes every unchanged-text row no longer match → all re-translated lazily on next encounter; old rows orphaned (optional startup `DELETE WHERE version != current`). **Edited source questions self-invalidate** independently: changed text → new key → fresh translation, old row orphaned. This is the manual refresh lever the founder asked for.
- **Cache-like behaviour preserved (unchanged from v1).** Durable lookup sits **after** each method's short-circuit; **store only on validated-success** (never the fallback/validation-fail/`except` returns) — the same `:157`/`:210` hook points. Errors and validation-fallbacks are **never persisted** (the durability requirement does not weaken the v1 poisoning guard).

**Class confirmation (durable scope) — STAYS class a, NO contradiction found.** A local SQLite file on the **existing** `/data` volume with schema auto-created via `Base.metadata.create_all` at init is **not an Alembic-tracked migration and not prod DDL** — `ratings.db` proves this exact precedent already runs in prod un-migrated. quiz-agent's own Alembic (`0001-0004`) owns only auth/usage tables; the corpus `questions` table is quiz-pack-api's. A repo-wide grep for `translation` across both `alembic/` trees returns **nothing**. No quiz-pack-api coupling, no cross-app DDL. → **class a (ready-for-agent)** holds for the durable store.

**Triage implication:** the cache-only or cache+sidecar path keeps **#69 as class a (ready-for-agent)** — pure app-layer + a committed data file + tests, migration-free. It becomes class b **only** if a translated DB column is chosen.

**Resolved (founder, 2026-06-29):** cache-only, SK-focused — offline pre-translation / sidecar and SK+CS coverage are deferred (the `(kind, text, language)` key generalizes to CS for free). The redeploy re-warm tradeoff (not *durably* zero-cost) is accepted. See **Scope**, **Resolved design decisions**, and the Locked scope decision.

## v1 shipped & superseded (2026-06-29)

The **in-memory** cache v1 shipped in `e27d562`: module constant `CACHE_MAX_ENTRIES = 2000`; instance
`self._cache: dict[(kind, text, lang) → str]` on the singleton; `_maybe_store` reads the cap at
call-time and stops inserting at the cap; lookup/store after each short-circuit; only validated
successes cached; no `asyncio.Lock`. 8/8 v1 tests + `test_translation_validation.py` green. **This
durable re-prep builds on those exact hook points** (the in-memory dict becomes a warm-loaded,
write-through front for the on-disk SQLite store); the v1 tasks/acceptance below are superseded.

## Tasks (atomic)

> **One task (impl + tests, one commit).** Considered a 2-way split (store class vs translator wiring),
> but rejected: total surface is small (~40-line store class + ~15-line wiring + ~120-line tests, one
> context), the seam is thin (the wiring can't be exercised without the store), and **every** acceptance
> criterion is an integration assertion on `TranslationService` — a split would land Task-1 tests that are
> a strict subset of Task-2's. Matches the v1 convention ("a cache without its test isn't done", `e27d562`).
> Class **a**: no Alembic, no prod DDL, no quiz-pack-api files.

- [x] **Durable warm-load + write-through translation store.** *(shipped 2026-07-06 — all acceptance tests below implemented and green, full backend suite 271 passed)* Layer an on-disk SQLite store behind the
  shipped v1 in-memory `self._cache`, reusing the v1 hook points (short-circuit → lookup → validated-success
  store) **unchanged** — this changes *where the value durably lives*, not *when* it is read/written.

  **New file `apps/quiz-agent/app/translation/store.py` — dedicated `TranslationStore` class** (mirrors
  `SQLClient`, `sql_client.py:70-90`; a dedicated class, not inline, keeps the four-column-PK + dialect-upsert
  logic isolated and unit-reachable). Use its **own** `declarative_base()` — **NOT** `sql_client.Base`, which
  would create ratings/scores tables inside `translations.db`. One model `TranslationRow` → table
  `translations`, columns `kind, source_text, target_language, version, translated_text`, **composite PK
  `(kind, source_text, target_language, version)`** (Decision #6).
  - `__init__(self, store_url)`: sync `create_engine(store_url)` + `Base.metadata.create_all(self.engine)` +
    `sessionmaker` — same idiom as `sql_client.py:84-86`. **No internal try/except** (the fail-soft guard
    lives in the service, wrapping construction + warm-load together — Decision #1).
  - `load_version(self, version) -> dict[tuple[str, str, str], str]`: `SELECT kind, source_text,
    target_language, translated_text FROM translations WHERE version = :version`; return a dict keyed by the
    **3-tuple `(kind, source_text, target_language)`** — version is implicit (warm-load only loads
    current-version rows), so the in-memory key shape is the v1 `(kind, text, lang)` **unchanged**.
  - `upsert(self, kind, source_text, target_language, version, translated_text)`: **SQLite-dialect upsert**
    (Decision #6, NOT the append-only `add_rating` ORM idiom) — `from sqlalchemy.dialects.sqlite import insert
    as sqlite_insert`; `sqlite_insert(TranslationRow.__table__).values(...).on_conflict_do_update(index_elements
    =["kind","source_text","target_language","version"], set_={"translated_text": ...})`; execute + commit.

  **`apps/quiz-agent/app/translation/translator.py` wiring** (add `import os` at top):
  - **Module constant `TRANSLATION_PROMPT_VERSION = "1"`** next to `CACHE_MAX_ENTRIES` (`:28-30`). The
    **single global** refresh lever covering **both** prompts (Decision #2, per-kind deferred). Read at
    **call-time** (like `CACHE_MAX_ENTRIES`) so a test can monkeypatch it.
  - `__init__` (`:40-50`): add param `store_url: str | None = None`, resolved to
    `store_url or os.getenv("TRANSLATION_CACHE_URL", "sqlite:///./data/translations.db")` (env name **locked
    = `TRANSLATION_CACHE_URL`**, default mirrors `main.py:204-205` → `/data` in prod via the mount; tests
    inject a `tmp_path` URL). **Fail-soft guard (Decision #1 — net-new, NOT inherited):** wrap **all three**
    init steps in **one** `try/except Exception` — `TranslationStore(store_url)` construction (engine-open +
    `create_all`) **and** `self._cache = self._store.load_version(TRANSLATION_PROMPT_VERSION)` (warm-load
    `SELECT`). Success → `self._store` set + `self._cache` warm-loaded. Failure → `logger.warning(...)`,
    `self._store = None`, `self._cache = {}` (degrade to empty in-memory cache; **never re-raise** — this
    `__init__` runs inside `main.py:324-326`'s `except: raise`, so any escape crash-loops the whole app on a
    bad `/data/translations.db`).
  - `_maybe_store` (`:52-60`): becomes the **single write-through point** (both call sites `:157`/`:210`
    already route through it, validated-success-only — the never-poison invariant is preserved). Decompose
    `key` into `(kind, text, lang)`. **In-memory dict insert FIRST**, under the existing
    `CACHE_MAX_ENTRIES` cap guard. **THEN** the durable write: **if `self._store is not None`** →
    `self._store.upsert(kind, text, lang, TRANSLATION_PROMPT_VERSION, value)` (SQLite is unbounded —
    Decision #4 — so always write, no cap). ⚠️ **The durable write MUST be best-effort (Phase-5 Gate B —
    runtime-write fail-soft):** wrap the `upsert(...)` in its **own** `try/except Exception:
    logger.warning(...)` that **swallows** — mirroring `add_rating`'s safe-write idiom (`sql_client.py:101-128`,
    which catches + returns `False`, never propagates). Rationale: `_maybe_store` runs **inside** the translate
    `try` (`:123`/`:185`; broad `except` at `:160`/`:213`), so an **unguarded** write error would be caught
    there and **return the original English despite a validated translation in hand** — and, sequenced after a
    failed write, would skip the in-memory cache too (→ re-translate-and-re-fail on every later call). Dict-
    insert-first + the swallowing guard make `_maybe_store` **unable to raise**, so a runtime disk hiccup
    (full `/data`, read-only/locked file) **never** alters the translate return value or the in-memory cache.
    Fail-soft therefore covers **both** init (Decision #1) **and** the runtime write. **Retry semantics
    (Phase-5 Gate B caution):** a key whose `upsert` failed is served from the in-memory dict for the rest of
    the process (the lookup short-circuit means it is **not** re-written within that process); it is
    re-attempted only after a restart, when the warm-load misses and the key is lazily re-translated + re-stored
    — the standard cache-aside best-effort-write tradeoff, fine for this single-user, finite-corpus app.
  - **No change** to: the `source==target`/`target=="en"` short-circuits (`:113`/`:175`), lookup-after-
    short-circuit (`:116-119`/`:178-181`), validated-success-only discipline, or the fallback returns
    (`:156`/`:162`/`:215`, still un-stored). `main.py:230` stays bare `TranslationService()` — it picks up the
    env default, so `main.py` is **untouched**.

  **Tests** (extend `apps/quiz-agent/tests/test_translation_cache.py`): update the `service` fixture to inject
  a per-test `tmp_path` store URL (`TranslationService(store_url=f"sqlite:///{tmp_path}/translations.db")`) so
  the 8 v1 tests stay isolated from `./data`, then add the durable tests in **## Acceptance** below.

## Acceptance

> Each criterion is one named pytest test in `apps/quiz-agent/tests/test_translation_cache.py` (extended).
> Durable tests build instances directly with an explicit `store_url=f"sqlite:///{tmp_path}/translations.db"`;
> on-disk assertions read the file via stdlib `sqlite3.connect(...)` (`SELECT ... FROM translations`),
> independent of the store class. **Run:**
> `cd apps/quiz-agent && pytest tests/test_translation_cache.py tests/test_translation_validation.py -v`

- [x] **Durability across instances (the core new proof) — `test_durable_across_instances`.** Instance #1
  (store at `tmp_path`) translates `("question", QUESTION, "sk")` → its mock `call_count == 1`. A **second**
  `TranslationService` at the **same path**, given a **fresh** AsyncMock, serves the same key: that instance's
  `call_count == 0` (no new LLM call across the instance boundary) and the result `== QUESTION_SK` (came from
  disk via warm-load, not the LLM).
- [x] **Warm-load — `test_warm_load_serves_from_disk`.** Pre-seed the file directly
  (`TranslationStore(url).upsert("question", QUESTION, "sk", TRANSLATION_PROMPT_VERSION, QUESTION_SK)`), then
  construct a fresh `TranslationService` at that path → `service._cache` is **non-empty** before any call, and
  serving the seeded key makes **0** LLM calls and returns `QUESTION_SK`.
- [x] **Version bump forces re-translate — `test_version_bump_forces_retranslate`.** Instance #1 persists a row
  at version `"1"`. `monkeypatch.setattr(translator_module, "TRANSLATION_PROMPT_VERSION", "2")`, then build a
  fresh instance at the same path: its warm-loaded `_cache` does **not** contain the old key, serving it makes
  **1** new LLM call (re-translate), and the old `version="1"` row is still on disk but **never served**
  (assert on-disk now holds both a `"1"` and a `"2"` row for the key).
- [x] **Question error + validation fallbacks never persisted to disk — `test_question_fallbacks_not_persisted_to_disk`.**
  Drive `translate_question` through `Exception → garbage("suchy bodliak") → QUESTION_SK` (side_effect list);
  after the sequence, a direct `sqlite3` `SELECT * FROM translations` returns **exactly one** row — the
  validated success — proving neither the `except`-fallback nor the validation-fail-fallback was written.
- [x] **Feedback error fallback never persisted to disk — `test_feedback_fallback_not_persisted_to_disk`.**
  Drive `translate_feedback` through `Exception → feedback_sk`; on-disk table holds **exactly one** row (the
  success), proving `translate_feedback`'s only non-success path (`except` → original) never reaches disk.
- [x] **No-op short-circuit not persisted — `test_noop_shortcircuit_no_disk_row`.**
  `translate_question(QUESTION, "en", "en")` and `translate_feedback("Correct!", "en")` → `call_count == 0`,
  `service._cache == {}`, **and** the `translations` table has **0** rows on disk (short-circuit returns
  before lookup/store, so no-op passthroughs touch neither memory nor disk).
- [x] **Fail-soft init (Gate B #1) — `test_fail_soft_init_degrades_to_empty_cache`.** Point the store at a
  **corrupt** DB file (write garbage bytes to `tmp_path/translations.db` first) → constructing
  `TranslationService` does **not** raise; `service._store is None` and `service._cache == {}`; a subsequent
  mocked `translate_question` still returns the translation (degrades to an empty in-memory cache, no crash).
  This is the test that proves the net-new guard the `ratings.db` precedent does not grant.
- [x] **Runtime write failure still serves the translation (Gate B #1) — `test_runtime_write_failure_still_serves_translation`.**
  Build a normal instance, then force the durable write to fail (e.g. monkeypatch `service._store.upsert` to
  raise, or close/corrupt the DB after init). `translate_question(QUESTION, "sk")` (valid mock) returns
  **`QUESTION_SK`** (the translation, **not** the original English) with `call_count == 1`; a **second** call
  on the same instance serves from the in-memory cache (`call_count` stays **1**) — proving a disk-write error
  neither downgrades serving to English nor skips the in-memory cache (the swallowing guard + dict-insert-first
  hold).
- [x] **Upsert is idempotent on the composite PK (Gate A) — `test_upsert_overwrites_existing_row`.**
  Directly `TranslationStore(url).upsert("question", QUESTION, "sk", V, "first")` then `upsert(... , "second")`
  for the **same** `(kind, source_text, target_language, version)` → a stdlib `sqlite3` `SELECT` shows **exactly
  one** row holding `"second"`. Pins the `on_conflict_do_update` upsert (a plain `INSERT` would raise
  `IntegrityError` here) — the one disk path the in-memory short-circuit otherwise hides — and disk-level
  `kind`-isolation.
- [x] **Repeat = one LLM call + kind isolation (carried v1, still valid) — `test_repeat_question_one_llm_call`,
  `test_repeat_feedback_one_llm_call`, `test_both_methods_cached_kind_isolates`** remain green under the
  `tmp_path`-injected `service` fixture (in-memory hit path + `kind` discriminator unchanged by the durable layer).
- [x] **No regression — full suite green.**
  `cd apps/quiz-agent && pytest tests/test_translation_cache.py tests/test_translation_validation.py -v`
  passes with **0** failures/skips (all 8 v1 cache tests + the new durable tests + the validation suite).
