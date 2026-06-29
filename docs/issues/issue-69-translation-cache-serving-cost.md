# Issue #69 — Cost: translation runtime cache (3.5× SK serving cost)

**Triage:** enhancement · ✅ done (2026-06-29)

**Created:** 2026-06-21 · **Founder:** Michal · **Source:** #64 full-project review (rank 19 — verified first-hand)

**Severity:** medium — the founder's device always runs Slovak, so every test session pays the penalty.

**Reversibility:** a — in-memory cache on `TranslationService` + one new test; no Alembic migration, schema, DB column, sidecar, auth, or payments. Fully revertable by removing the cache.

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done | recon verified first-hand; build-vs-adopt locked |
| 2 · Plan              | ✅ done | scope locked (cache-only), decisions resolved |
| 3 · Plan review       | ✅ done | ready-check **READY** · design-soundness **SOUND 0.88** |
| 4 · Impl-plan         | ✅ done | 1 atomic task + machine-evaluable acceptance |
| 5 · Impl-plan review  | ✅ done | ready-check **READY** · design-soundness **SOUND 0.88** |
| 6 · Split             | ✅ done | single-session — no execution-prompts file; class **a** |

**Last updated:** 2026-06-29 · **Status:** ✅ **PREP COMPLETE — ready-for-agent** · all 6 phases done · **Gate attempts:** P3 1/3 (passed) · P5 1/3 (passed)

**Locked scope decision (founder, 2026-06-29):** runtime instance cache **only** — questions translate at runtime one-by-one and the cache catches recurrences. **No** offline corpus pre-translation (JSON sidecar / DB column) in this issue → keeps #69 **class a (ready-for-agent)**, migration-free. Offline pre-translation deferred as a future option, not built here.

## Why

Translation makes a fresh `gpt-4o-mini` call per question/feedback with **no caching** — ~2 LLM
translate calls per answered cycle. Issue #49 measured SK sessions at `$0.00231` vs `$0.000657`
for EN — a **~3.5× multiplier**, entirely from translation — and the founder's device always runs
Slovak, so every test session pays it. The ~580-question approved corpus is **finite**, so the same
questions recur; caching validated translations for the process lifetime removes almost all of the
repeat cost.

## Scope

**In scope**
- An instance cache on the `TranslationService` singleton, covering **both** async methods
  (`translate_question` and `translate_feedback`).
- A regression test proving a repeated `(kind, text, language)` translates via **one** LLM call
  (the second is a cache hit) and that the cache persists across requests (instance-level).

**Out of scope / deferred**
- Offline one-time pre-translation of the approved corpus (the ~$0.07 batch) — deferred as a
  future durable-zero-cost option, not built here.
- A JSON sidecar of pre-translated questions, and a translated `questions` DB column / Alembic
  migration (the column would flip #69 to **class b / ready-for-human** and cross-app-couple DDL).
- CS-specific work — the cache key already generalizes to CS for free (see below); no CS corpus
  pass is part of this issue.

## Resolved design decisions

- **Cache structure — a plain instance `dict`.** `self._cache: dict[tuple[str, str, str], str]` on
  the singleton, keyed `(kind, text, target_language)` with `kind ∈ {"question", "feedback"}`. The
  two methods use **different prompts**, so the `kind` discriminator prevents a cross-method
  collision on identical text. Soft size guard at ~2000 entries; **store only validated successes** —
  never the fallback-to-original — so a transient LLM/validation error is not poisoned into the
  cache. Insert the lookup/store **after** each method's existing short-circuit (`source==target` /
  `target=="en"` already return early), so no-op passthroughs are never cached.
- **A dict, not `functools.lru_cache` / `cachetools`.** `lru_cache` cannot wrap an async method (it
  caches the returned coroutine and keys on `self`); `cachetools` is not a repo dependency. Corpus
  cardinality ≈1740 text variants (≈580 questions × ~3) sits under the ~2000 cap, so eviction
  essentially never fires and a real LRU policy buys nothing. A plain dict is async-safe,
  dependency-free, and matches the repo's minimal-deps bias. (`cachetools.LRUCache` is the only
  true-LRU alternative — not worth a new dependency for a cap that never triggers.)
- **Instance cache satisfies "persists across a session, not per-request."** `TranslationService` is
  a **process-wide singleton**: built once at startup (`main.py:230`), held on `app.state`
  (`main.py:372`), injected via `get_translation_service` (`api/deps.py:378`). An instance-level
  cache therefore survives every request and session for the process lifetime — the criterion is
  met with **zero extra plumbing**.
- **Second-order fit (D11), without over-building.** The `(kind, text, language)` key already
  generalizes to CS or any future language with **zero rework**, and the cache is a thin layer in
  front of the existing client call — it leaves room for a future durable sidecar / corpus
  pre-translation without restructuring. Neither is built now. **The one real tradeoff, flagged
  plainly:** the in-memory cache is wiped on every Fly redeploy and re-warms per process, so it is
  not *durably* zero-cost — acceptable under the locked cache-only scope (always-Slovak sessions
  re-warm within the process; durable zero-cost is the deferred offline option).
- **Size-guard behavior — stop inserting at the cap (Phase-3 Gate B).** `CACHE_MAX_ENTRIES = 2000`
  module constant; once `len(self._cache) >= CACHE_MAX_ENTRIES` the methods **stop inserting new
  keys** while still serving existing hits and pass-through-translating misses. Provably bounded at
  ≤ cap, no eviction bookkeeping, no new dependency; unlike clear-on-cap it never discards an
  already-warm corpus, so it stays safe even if the ~1740 estimate is low. Recon (`serializers.py:43`)
  confirms **only question text + correct-answer feedback are translated — options/distractors are
  not** — so SK-only realistic cardinality is ~1160, well under the cap; the guard is a soft safety
  valve, not a hot-path concern.
- **Cache-stampede — accepted non-issue, no lock (Phase-3 Gate).** The async check-then-set is
  intentionally unsynchronized: two simultaneous identical requests could both miss and both
  translate. The founder's use is sequential/single-user, so the worst case is one wasted duplicate
  call — never incorrectness. No `asyncio.Lock` is added (contention + complexity for a case that
  does not occur). Concurrency-safety is therefore **not** an acceptance criterion.

## Evidence (verified first-hand 2026-06-21)

- `apps/quiz-agent/app/translation/translator.py` — no `@lru_cache`, no instance cache.
- `apps/quiz-agent/app/quiz/flow.py:146,178,280-283` — translate calls per question cycle (feedback ×2 + next-question text ×1).
- Cross-ref: `docs/artifacts/daily-limit-cost-model.html` / #49 ($0.00231 SK vs $0.000657 EN).
- (The `fly_client_ip` rate-limiter default fix that the review bundled here is owned by **#65** to avoid a split fix — not duplicated.)

## Research (Phase 1)

*Web pass: NOT run — internal caching/storage problem. The only library question (cachetools vs stdlib) is settled by in-repo evidence (cachetools absent + async-method constraint). No open external unknown a maintained-library check could answer.*

### Strand A — Code recon (verified first-hand 2026-06-29)

- **"No cache" confirmed.** `translator.py` `TranslationService` has no `@lru_cache`/instance cache. Two public **async** methods: `translate_question(question, target_language, source_language="en")` (`translator.py:81`, prompt + `max_tokens=300`) and `translate_feedback(feedback, target_language)` (`translator.py:140`, `max_tokens=50`). Both call `self.client.chat.completions.create(...)` (async OpenAI from `llm_factory.openai_client(async_=True)`, `translator.py:41`). Both short-circuit when `source==target` / `target=="en"`.
- **Lifecycle = process singleton (KEY for the cache).** Built once at startup `main.py:230` (lifespan), held as module global `main.py:89` + `app.state.translation_service` `main.py:372`, injected everywhere via `get_translation_service → request.app.state.translation_service` (`api/deps.py:378`). → an **instance-level cache survives across all requests/sessions for the process lifetime** — satisfies the "persists across a session, not per-request" criterion with **no extra plumbing**.
- **Call-sites verified** (`flow.py`): `:146` (answer branch) and `:175` (skip branch) both → `_translate_correct_answer` → `translate_feedback`; `:280-283` → `question_to_dict_translated` → `translate_question` (`serializers.py:54`). Per **answered** cycle = **2 distinct LLM translate calls** (1 feedback correct-answer + 1 next-question), not 3 — answer/skip are mutually exclusive branches. (Issue's "feedback ×2 + next ×1 = 3" over-counts, or folds in the initial-question fetch at `quiz.py:151` / `tts.py:82`; immaterial to design.) Shapes: long question text via `translate_question` vs short answer string via `translate_feedback` — **different methods/prompts**, so the cache key should include a `kind` discriminator to avoid a cross-method collision.
- **Corpus store + head migration.** Approved corpus = Postgres **`questions` table (pgvector)**; schema = SQLAlchemy `questions_table` (`packages/shared/quiz_shared/database/pgvector_client.py:60-92`); served read-only on the hot path by `PgvectorQuestionStore` via `QuestionRetriever`. **DDL is owned by quiz-pack-api Alembic** — migration `1c5e0fa7b3d4_core_entities` (`op.create_table("questions", …)`). **Head = `1c5e0fa7b3d4`** (→ baseline `29f509ffa769`). quiz-agent's own alembic (`0001-0004`) owns only auth/usage tables (#60), **not** the corpus. **No translation column exists anywhere.**
- **Test idiom** (`tests/test_translation_validation.py`): fixture builds `TranslationService()` under `patch.dict(os.environ, {"OPENAI_API_KEY": "sk-test-dummy"})`; tests replace `service.client.chat.completions.create = AsyncMock(return_value=<MagicMock with .choices[0].message.content>)` (`:122`, helper `_mock_openai_response` `:109`) and drive via `asyncio.run(...)`. A cache test follows this exactly: set the AsyncMock, call the method twice with the same `(text, lang)`, assert `service.client.chat.completions.create.call_count == 1` and that both results are equal.

### Strand B — Build-vs-adopt (D10)

- **Runtime cache → BUILD a plain instance dict.** In-repo idiom: `functools.lru_cache(maxsize=1)` only on *sync* singleton getters (`quiz-pack-api config.py:47`, `deps.py:33`); `cachetools` is **not** a dependency anywhere; TTS uses a bespoke disk-backed `TTSCache` (heavier than needed). `functools.lru_cache` **cannot** wrap async methods (caches the coroutine; keys on `self`). Cardinality ≈ 580×3 ≈ 1740 < 2000 cap → eviction rarely fires, so a sophisticated LRU policy buys little. → `self._cache: dict[(kind, text, lang) → str]` on the singleton, simple size guard at ~2000, and **cache only validated successes** (don't cache the fallback-to-original, so a transient LLM error isn't poisoned). No new dependency, async-safe, matches the repo's minimal-deps bias. (`cachetools.LRUCache` is the only real alternative if true LRU eviction is wanted — not worth a new dep for a cap that is essentially never hit.)
- **Offline corpus pre-translation → JSON sidecar; AVOID the DB column.**
  - **JSON sidecar** (committed file mapping question id/text → `{sk, cs}`): **no migration**, no schema/prod-DB change → keeps the issue **class a (ready-for-agent)**.
  - **Translated `questions` column** (e.g. `translations JSONB`): requires an **Alembic migration in quiz-pack-api** (head `1c5e0fa7b3d4` → new revision) **+ a prod DB apply** → flips the issue to **class b (ready-for-human)**; also cross-app couples DDL (quiz-pack-api) with serving (quiz-agent).
  - **Verdict:** runtime instance cache + (optional) JSON sidecar. The DB column is the **only** option that needs a migration → not recommended for this issue.

**Triage implication:** the cache-only or cache+sidecar path keeps **#69 as class a (ready-for-agent)** — pure app-layer + a committed data file + tests, migration-free. It becomes class b **only** if a translated DB column is chosen.

**Resolved (founder, 2026-06-29):** cache-only, SK-focused — offline pre-translation / sidecar and SK+CS coverage are deferred (the `(kind, text, language)` key generalizes to CS for free). The redeploy re-warm tradeoff (not *durably* zero-cost) is accepted. See **Scope**, **Resolved design decisions**, and the Locked scope decision.

## Implemented (2026-06-29)

Shipped in `translator.py` + new `tests/test_translation_cache.py`. Module constant
`CACHE_MAX_ENTRIES = 2000`; instance `self._cache: dict[(kind, text, lang) → str]` on the
singleton; private `_maybe_store` reads the module-global cap at call-time (test-monkeypatchable)
and stops inserting at the cap. Lookup/store sit after each method's short-circuit; only validated
successes are cached (no fallback/validation-fail/except poisoning). No `asyncio.Lock` (stampede
accepted). 8/8 new tests + `test_translation_validation.py` green; ruff clean. (Full-suite auth/usage
tests need a local Postgres and erred on connection in dev — pre-existing infra, unrelated.)

## Tasks (atomic)

- [x] **Add a process-lifetime translation cache to `TranslationService` — implementation + regression test, one commit.** (A cache without its test isn't done; both files land together.)
  - `apps/quiz-agent/app/translation/translator.py`:
    - Module constant `CACHE_MAX_ENTRIES = 2000`. In `__init__` add `self._cache: dict[tuple[str, str, str], str] = {}`.
    - `translate_question` — **after** the `source_language == target_language` short-circuit (`:95-96`): `key = ("question", question, target_language)`; `if key in self._cache: return self._cache[key]`. Store **only on the validated-success path** (`return validated`, `:134`) and only while `len(self._cache) < CACHE_MAX_ENTRIES`. Do **not** store on the validation-fail or `except` fallbacks (both `return question`, `:133`/`:138`).
    - `translate_feedback` — **after** the `target_language == "en"` short-circuit (`:151-152`): `key = ("feedback", feedback, target_language)`; same lookup; store on the success path (`return translated`, `:181`) under the same `< CACHE_MAX_ENTRIES` guard. Do **not** store on the `except` fallback (`return feedback`, `:185`).
    - Size guard = **stop inserting new keys once `len(self._cache) >= CACHE_MAX_ENTRIES`** (existing hits still served, misses still translate); no eviction, no new dependency. The guard must reference the **module-global `CACHE_MAX_ENTRIES` at call-time** (the bare name resolved from module scope — do *not* copy it into `self`), so a test can monkeypatch the cap. No `asyncio.Lock` (stampede is an accepted single-user non-issue — see Resolved design decisions).
  - `apps/quiz-agent/tests/test_translation_cache.py` (new) — follows the `tests/test_translation_validation.py` idiom (`service` fixture under `patch.dict(os.environ, {"OPENAI_API_KEY": ...})`; `service.client.chat.completions.create = AsyncMock(...)`; drive via `asyncio.run`; assert `.call_count`). Implements every Acceptance test below.

## Acceptance

> Machine-evaluable. New regression test: `apps/quiz-agent/tests/test_translation_cache.py`. Run it with `cd apps/quiz-agent && pytest tests/test_translation_cache.py -v`.

- [x] **Repeat = one LLM call.** `test_repeat_question_one_llm_call`: AsyncMock returns a valid translation; `translate_question(T, "sk")` called **twice on the same `service` instance** → `service.client.chat.completions.create.call_count == 1` and both return values equal.
- [x] **Persists across requests (instance-level, not per-request).** The repeat calls above reuse **one** `TranslationService` instance with no new instance constructed between them — proving the cache lives on the singleton. Asserted by `test_repeat_question_one_llm_call` plus `test_repeat_feedback_one_llm_call` (same for `translate_feedback`).
- [x] **Both methods cached; `kind` prevents cross-method collision.** `test_both_methods_cached_kind_isolates`: same text `T` to `translate_question(T, "sk")` and `translate_feedback(T, "sk")` → first pass `call_count == 2` (independent misses — the `kind` discriminator stops identical text from colliding across methods); repeating both calls → still `== 2` (both now hits).
- [x] **Fallback / error is NOT cached (both methods).** `test_error_then_success_recomputes`: `AsyncMock(side_effect=[Exception(...), <valid response>])` → first `translate_question` returns the original (fallback), second returns the translation with `call_count == 2` (a later success still calls the LLM ⇒ the fallback was never cached). `test_validation_fail_then_success_recomputes`: first response is garbage (`"suchy bodliak"` → original), second valid → `call_count == 2`. `test_feedback_error_then_success_recomputes`: same `side_effect=[Exception, <valid>]` against **`translate_feedback`** → `call_count == 2` (its `except` fallback at `:185`, its only non-success path, is likewise never cached).
- [x] **No-op short-circuit is NOT cached.** `test_noop_shortcircuit_untouched`: `translate_question(T, "en", "en")` and `translate_feedback(T, "en")` return the input with `service.client.chat.completions.create.call_count == 0` **and** `service._cache == {}`.
- [x] **Memory bounded at ≤ cap.** `test_cache_bounded_at_cap`: monkeypatch `app.translation.translator.CACHE_MAX_ENTRIES` to a small `N` **after** the `service` fixture is built, then translate more than `N` distinct texts **with valid mock responses** (so each is a real validated store that actually exercises the guard, not a vacuous pass) → `len(service._cache) <= N` (guard stops inserting past the cap; existing entries still serve).
- [x] **No regression.** Translation suite green: `cd apps/quiz-agent && pytest tests/test_translation_cache.py tests/test_translation_validation.py -v` (validation/fallback behavior unchanged). Broader suite's auth/usage tests require a live Postgres (absent in this dev env) and are unaffected by this change.
