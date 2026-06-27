# Issue #72 — Question generation-quality overhaul (all types)

**Triage:** enhancement · ralph-runnable (autonomous build + offline gates; one founder-authorized validation run at the end)

**Reversibility:** a · commits-only, every new behaviour behind a dormant toggle (no schema/data migration, no auth/payment, no prod deploy, no corpus writes) — overnight-loop eligible for **Phases 0–5 only**; Phase 6 is a human checkpoint Ralph must not cross.

**Created:** 2026-06-22 · **Refocused:** 2026-06-22 (founder) · **Founder:** Michal

**Execution status (2026-06-23):** Phases 0–5 ready to run on `mba` via Ralph (Opus 4.8 @ max effort). The
2026-06-22 launch went gate-red after 2 good iterations (P0.1/P0.2) due to **environment drift on `mba`, not
#72 code** — the scoped gate runs the full quiz-pack-api suite but `mba` then had no Postgres/Redis.
**[[issue-73-mba-postgres-redis-dev-env]] is RESOLVED (2026-06-23):** colima Postgres+Redis are up on `mba`
and the scoped gate is green (402 passed / 0 failed, verified first-hand this session). **Unblocked —
launching Phases 0–5 on 2026-06-23.** Launch + oversight prompt:
`docs/handoffs/handoff-2026-06-23-1018.md`. Founder steer: a new session launches and oversees; Ralph runs
Phases 0–5 only and must never cross the 🛑 Phase-6 line.

**Branch-state note (2026-06-23, this run):** P0.1/P0.2 from the 2026-06-22 launch landed on sibling branch
`ralph/overnight-20260622-2142` (commits `27c086d`, `2088db3`) but that branch hit the #73 gate-red blocker
and was **never merged**. The current branch (`ralph/overnight-20260623-1132`, == `main` post-#73) does
**not** contain them — `app/feature_flags.py` is absent here. P0.1 re-recorded fresh below;
**P0.2 can be cherry-picked from `2088db3`** (`app/feature_flags.py` + 15 tests, verified green there)
rather than redone.

## Why

This issue is about **raising the QUALITY of question generation** for **every question type** —
`text` (open), `text_multichoice` (MCQ), `true_false`, and any future type. The trigger was boring,
first-degree-recall output ("prvoplánové", e.g. *"What term do sailors use for the right side? →
Starboard"*), but the scope is the **generation flow itself**, not a content campaign.

**Explicitly OUT of scope (founder, 2026-06-22):**
- ❌ **Generating new questions for the corpus / release.** That is [[issue-30-batch-generate-categories]];
  the founder owns the trigger and will run it after this flow is excellent. #72 must not carry it.
- ❌ **Evaluating / re-scoring / sweeping the already-generated corpus.** The existing corpus may largely
  be discarded; auditing it is not the point. (This removes the old Phase-4/5/7a corpus-scoring work.)
- ❌ **Re-litigating Tavily / the web-search provider.** Settled (keep Tavily PAYG —
  memory `project_web_search_provider`). Tavily appears here only as one small supporting input fix, not a pillar.

**Two founder intuitions — both confirmed by research this turn:**
1. *"It used to be better a few months ago."* ✅ **True and pinpointed.** Text-gen quality degraded on
   **2026-05-20** via three compounding commits (see Diagnosis). The good Feb–Apr creative machinery was
   never deleted — it is **loaded but bypassed** in production.
2. *"With OpenRouter we shouldn't be stuck on the current models — better ones likely exist."* ✅ **True.**
   The creative-generation step still runs **GPT-4o**, which ranks well below the Claude Opus line on
   creative-writing benchmarks. The OpenRouter gateway (#53) is already shipped, so the swap is config-only.

## Diagnosis — what actually went wrong

### A. The degradation has a date and three causes (archaeology)

Peak text quality was **2026-02-17 → 2026-02-20** (`c21a982`, `471c41b`): generation drew on the model's
own knowledge through the rich `v2_cot` prompt (Pattern Library 1–13, Answerability dimension, "Engagement
Path over Dead End" principle, Structural-Monotony red flags), with **fact-grounding opt-in**, driven by a
strong creative model. On **2026-05-20** (under #36) three commits silently inverted that:

| Commit | Change | Effect on text quality |
|--------|--------|------------------------|
| `6aa70b6` | **SourcingStage made mandatory + first.** `source_facts` is now always present, so `use_fact_first` (advanced_generator.py:520) is **always true** → the hard-bound `v3_fact_first` prompt is **always** used; the richer `v2_cot` creative path is **loaded but never reached**. | **WORST** — creative latitude removed in every production run |
| `7d83f11` | Basic generator deleted; all traffic routed to `AdvancedQuestionGenerator` whose ctor default is **`generation_model='gpt-4o'`**. The old `claude-opus`-driven script became an orphan (now git-historical only). | Model downgrade for creativity |
| `91de085` | News / CZ-SK fact sources deleted → sourcing narrowed to Wikipedia (dry snippets) + OpenTDB (re-wraps trivia questions as "facts") + Tavily (quota-fragile). | Input material got duller |

**Net:** every question is now hard-chained to a dull source fact, generated by a non-creative model, with
the engagement-path machinery sitting unused one branch away. This is *exactly* the founder's "it got worse."

### B. The pipeline is a boring-question amplifier (structural root causes)

Fun is measured in ~5 places and **enforced in 0**; several gates actively select *for* boring. RC numbers
map to `docs/artifacts/question-quality-fun-review-2026-06-22.html`. All verified in code:

- **RC-1** OpenTDB re-wraps the trivia *question* as the "fact" (`opentriviadb_source.py:98` —
  `"The answer to '{question}' is {answer}."`), so "transform, don't rephrase" has nothing to transform. ✓
- **RC-5** `v3_fact_first` has **no escape hatch** — no room for a surprising *angle*. (`…v3_fact_first.md:22`) ✓
- **RC-9** FactVerifier agreement is naive substring (`agrees = answer_lower in content`,
  `fact_verifier.py:89`): crisp recall answers match verbatim and pass; estimation/reasoning answers don't →
  **dropped at the 0.5 gate. Verification selects FOR boring.** ✓ (Fix this BEFORE any gate-tightening.)
- **RC-10/11** Only live gate is `MIN_OVERALL_SCORE = 3.0` ("deliberately lenient", `scoring.py:44`); the
  calibrated Answerability/dead-end veto from `question_critique_v2` is **advisory-only, never wired**. ✓
- **RC-6** The 4 MCQ patterns (`true_false, odd_one_out, comparison_bet_older_larger, year_guess`) are the
  strict complement of the fun reasoning patterns — Estimation/Reverse/Lateral are **locked out of MCQ**. ✓
- **RC-2** `surprise_rating` is a flat fabricated default everywhere; `top_by_surprise()` has **zero call
  sites** → the prompt's "surprise ≥ 5 preferred" is a no-op. ✓
- **RC-7** MCQ path skips best-of-N critique. **RC-8** few-shot library is type-blind (≈3/53 MCQ examples).
  **RC-3** Tavily reach throttled to ~1 generic query/topic. **RC-4** Wikipedia returns search snippets, not facts.
- Dead-at-scale: `OPEN_SHAPE_FRACTION = 0.04` → `round(10×0.04)=0` open questions on a standard order
  (`generation.py:37`); `AnswerNormalizer` exists but is **not wired** (`generate_pack.py`); `themed`/`kids`
  prompts exist but are **never loaded**. ✓

## The levers (ordered by leverage)

The two the founder emphasized are A and B. C and D stop the pipeline from undoing them.

**Lever A — Better generation model via OpenRouter (config-only, dormant).**
Swap the creative-generation step off GPT-4o. Make `generation_model` / `critique_model` configurable
(env/config, not hardcoded at the call site), add the chosen OpenRouter slug to `_REMAP_OPENROUTER` in
`quiz_shared.llm.factory` (per #53 contract — never at the call site), and default it to the recommended
model. No behaviour changes until the gateway/flag is enabled. See **Model recommendation** below.

**Lever B — Restore creative latitude WITHOUT losing factual grounding (un-degrade the flow).**
Do *not* revert to pure-imagination generation (the driving app needs trust; that risk is why v3 exists).
Instead get the old quality *with* grounding:
- **Port the 471c41b engagement-path machinery into the live `v3` path** — Patterns 11–13 (Estimation,
  Comparison Bet, Reverse Engineer), the Answerability dimension, "Engagement Path over Dead End", and the
  Structural-Monotony red flags were added to `v2_cot` then **never backported to `v3`**. Low-risk, high-value.
- **Add the v3 escape hatch (RC-5):** allow a surprising *angle* from general knowledge **as long as the
  factual claim still traces to a source**. This is "angle-first, fact-grounded" — the spirit of the old
  flow, kept safe. Behind its own revertible toggle (highest-risk prompt change).
- **Fix the boring inputs (RC-1):** stop OpenTDB re-wrapping; emit a bare declarative fact (rewrite via a
  cheap model) so even hard-bound generation has good raw material.

**Lever C — Stop the gates from selecting FOR boring.**
- **RC-9 first** (must precede any gate tightening): fix FactVerifier agreement so non-recall answers can
  pass; when search/judge is unavailable, **tag `unverified` + hold for review** instead of dropping at
  confidence 0. Keep it strict for crisp factual claims.
- **Wire Answerability/surprise as a real veto** (RC-10/11) into the live scorer, with `critique_v2`
  calibration anchors — as **shadow first** (log what *would* drop, drop nothing) until proven.

**Lever D — All types, not just text.**
- **Unlock fun MCQ patterns** (RC-6): add the chosen reasoning pattern(s) to `PATTERNS_TO_MCQ` with recipes;
  broaden "comparison bet" via its recipe string, not a key rename (alias already exists, `pattern_routing.py:48`).
- **Revive the open/lateral branch** (raise/repair `OPEN_SHAPE_FRACTION` rounding so it isn't dead on small orders).
- **Restore an MCQ-path quality gate** (RC-7): best-of-N + `self_critique` telemetry for MCQ.

## Model recommendation (research-backed)

Generation runs through the #53 LLM factory, so this is a config/remap change, not a rewrite. **Grounded**
rows are cross-checked against Anthropic's current model docs; **verify-live** rows must be confirmed against
the live OpenRouter catalog (IDs/pricing shift, and some slugs use `.` vs `-`) before wiring.

| Step | Recommended | $/1M (in/out) | Why | Status |
|------|-------------|---------------|-----|--------|
| **Creative generation** (the primary fix) | **`claude-opus-4-8`** | $5 / $25 | Top creative-writing tier; "transform, don't rephrase" and lateral angles are exactly where it beats GPT-4o. ~$1–2 per 100 questions. | **grounded** |
| Cheap rewrite / normalize | `claude-haiku-4-5` (200K) | $1 / $5 | Best structured-JSON adherence per cost; the OpenTDB-fact and answer-normalize rewrites need reliability, not creativity. (`gpt-4o-mini` $0.15/$0.60 stays a valid cheaper option.) | **grounded** |
| Scoring / veto judge | `claude-sonnet-4-6` (already the 2nd scorer) | $3 / $15 | Opus-tier judgment at lower cost; nuanced rubric + reliable score JSON. | **grounded** |
| Fact verification | Gemini 2.5 (Flash in use; Pro if accuracy needed) | $0.30/$2.50 · $1.25/$10 | Top FACTS-benchmark accuracy; read-heavy, short-out step. | verify-live |
| Higher-ceiling A/B (optional) | `claude-fable-5` | $10 / $50 | Anthropic's most capable; only worth an A/B against Opus 4.8 if Opus output still feels flat. | verify-live |

Secondary creative candidates surfaced by research (Grok 4.x, GPT-5.x, Gemini 2.5 Pro, Qwen3-235B, DeepSeek
V3.2) are **unverified** — treat their IDs/pricing as hypotheses to confirm against the live catalog if Opus
4.8 is rejected on cost. **Do not hardcode any slug; verify at `openrouter.ai` first.** (A research stream
claimed Fable 5 is "suspended" — unverified and contradicted by Anthropic's own docs; ignored.)

## Plan (offline-first, Ralph-runnable)

> **Discipline (founder mandate, verbatim):** *"nechcem ziadny re-run spustat kym nie je flow generovania
> otazok upraveny a vynikajuci."* → Build everything **dormant behind toggles**, validate **offline** as far
> as honestly possible, and spend **exactly one** founder-authorized validation run at the very end. **Every
> Phase 0–5 gate proves PLUMBING-CORRECT, NOT FUN.** Ralph runs Phases 0–5 autonomously and **stops** at the
> Phase-6 authorization line.

**Phase 0 — Baseline + dormant flags (no LLM).** Suite green offline (~139 tests). Add every new behaviour
behind dormant flags (`GENERATION_MODEL` config, `V3_ESCAPE_HATCH`, `VETO_SHADOW`, etc.); nothing changes
output. Do **not** flip `LLM_GATEWAY` repo-wide (global; affects verify + gen) — scope it, or set it only at
Phase 6. *Gate:* suite green, flags dormant.

**Phase 1 — Lever A wiring + deterministic code fixes (no LLM).** Make generation/critique models
configurable + add the slug to `_REMAP_OPENROUTER` (default to `claude-opus-4-8`, dormant). **RC-9 fix**
(must land before any gate work). MCQ crash isolation (`return_exceptions=True` + per-sub-batch try/except,
advanced_generator.py:396 — = #42 task 42.31). Unlock the chosen MCQ pattern(s) in `PATTERNS_TO_MCQ` + recipes.
Repair `OPEN_SHAPE_FRACTION` rounding. *Gate:* unit tests green, incl. a test proving a non-substring
estimation answer is **not** dropped by the verifier, and the new MCQ pattern routes as decided.

**Phase 2 — Lever B prompt restoration (read-only, no LLM).** Backport the 471c41b engagement-path machinery
(Patterns 11–13, Answerability, Engagement-Path principle, Structural-Monotony red flags) into the live `v3`
prompt. Add the **escape hatch** behind `V3_ESCAPE_HATCH` (fully revertible). Thread `question_type` into
few-shot loading so MCQ batches see MCQ exemplars (answer-stripped). *Gate:* prompt-content assertions +
exemplar-count/schema tests.

**Phase 3 — Input fixes under mocks (no real network).** RC-1 OpenTDB → bare declarative fact (rewrite via the
cheap model) with a guard asserting output never contains the original question substring. Wire
`top_by_surprise()` + a free heuristic surprise score (no per-fact LLM). Minor Tavily/Wikipedia input
tidy-ups (de-emphasized — small templates fix only). *Gate:* respx `assert_all_mocked=True`; request/parse/guards correct.

**Phase 4 — Scoring veto as SHADOW (deterministic mocks).** Wire the Answerability/surprise veto into the live
scorer with `critique_v2` anchors, **`VETO_SHADOW` mode** (log would-drops, drop nothing). Restore MCQ-path
best-of-N + `self_critique` telemetry. *Gate:* veto plumbing unit-tested; shadow logs sane on synthetic
fixtures. (No corpus dependency — corpus-eval is out of scope.)

**Phase 5 — Validation harness, dormant (no LLM).** `scripts/validate_generation.py`: runs the reworked flow
on a small fixed set of dev topics across **all types** and asserts machine-checkable quality proxies — no
crash; ≥1 working non-recall pattern per type; pattern-diversity ≥ threshold; zero banned openers ("What is
the capital…/Who wrote…/What year did…"); ≤30% "Which" openers; MCQ JSON valid + distractor rules; answer
brevity. Guard so it can **never** write to the corpus. *Gate:* harness unit-tested on synthetic data; dry-run shape OK.

**Phase 6 — The ONE run = founder-authorized validation (the only spend).** *Ralph stops here and requests
authorization.* Budget ~$5 (plan 2–3× for an escape-hatch fix + rerun; keep it toggle-revertible).
- **6a — flow-validation run:** one small **mixed batch across all types** (text + MCQ + true_false, ~20–30)
  through the reworked pipeline with `claude-opus-4-8` enabled. Throwaway output — **this validates the flow,
  it is not corpus content and is not new-gen for release.** Confirm every Phase-5 proxy holds on real output,
  and that `VETO_SHADOW` would catch the dull ones without false-vetoing good ones.
- **6b — HUMAN LISTEN (the real arbiter):** founder listens to 6a hands-free and judges "prvoplánové vs fun".
  **No LLM-judge proxy replaces this.**
- *Gate:* flow is "excellent" (un-park) **only if** 6a proxies hold **and** 6b (the founder's ear) says less boring.

## Ralph task list (Phases 0–5 — offline, no paid generation)

Atomic units for the loop; full detail lives in **Plan** above. One iteration ≈ one box.
Each box's *Gate* is the machine check that must be green before it counts as done.

**Phase 0 — baseline + dormant flags (no LLM)**
- [x] **P0.1** Record the offline baseline: full suite green. *Gate:* suite green. ✅ **2026-06-23 (branch `ralph/overnight-20260623-1132`):** quiz-pack-api offline suite = **402 passed, 0 failed**, 1 skipped (Apple-root, setup-gated), 3 xfailed (worker stubs, post-#36 task 2.10) in ~74s via `.venv/bin/python -m pytest tests/`. (Plan's "~139" figure was stale; 406 tests collected.)
- [x] **P0.2** Add dormant flags (`GENERATION_MODEL`, `V3_ESCAPE_HATCH`, `VETO_SHADOW`, …); do **not** flip `LLM_GATEWAY` repo-wide. *Gate:* suite green, output unchanged with flags off. ✅ **2026-06-23 (branch `ralph/overnight-20260623-1132`):** cherry-picked the two code files from `2088db3` (the docs hunk there targeted the stale 2026-06-22 P0.1 text, so it was re-authored fresh here). New `apps/quiz-pack-api/app/feature_flags.py` declares four env-driven accessors — `generation_model`/`critique_model` (Lever A, default `None`→keep gpt-4o/gpt-4o-mini), `v3_escape_hatch` (Lever B, default off), `veto_shadow` (Lever C, default off). Env-driven to match the gen layer's inline `os.getenv()` convention (not Pydantic `Settings`, infra-only); **nothing reads them yet**, so output is unchanged. `LLM_GATEWAY` deliberately untouched. *Gate met:* `tests/test_feature_flags.py` (15 cases) proves dormant defaults + forgiving truthy parsing; full offline suite **417 passed** (402 baseline + 15 new), 1 skipped, 3 xfailed, 0 failed in ~83s via `.venv/bin/python -m pytest tests/`.

**Phase 1 — Lever A wiring + deterministic fixes (no LLM)**
- [x] **P1.1** Make generation/critique models config-driven; add `claude-opus-4-8` to `_REMAP_OPENROUTER` (dormant default, never hardcode at call site). *Gate:* unit test on config resolution. ✅ **2026-06-23 (branch `ralph/overnight-20260623-1132`):** `routes.py` now builds the generator via `_build_advanced_generator()`, sourcing models from the P0.2 Lever-A flags (`feature_flags.generation_model()/critique_model()`) and falling back to the factory role constants `llm_factory.GEN`/`CRITIQUE` (= `gpt-4o`/`gpt-4o-mini`) when unset — so with no env the models are byte-identical to today (dormant). Added `"claude-opus-4-8": "anthropic/claude-opus-4.8"` to `_REMAP_OPENROUTER` (slug follows the `claude-sonnet-4-6`→`anthropic/claude-sonnet-4.6` convention; flagged verify-live before the Phase-6 flip). No slug at the call site — the override passes a direct id, the factory translates it (#53 contract). *Gate met:* `test_generation_model_config.py` (3 cases: dormant default keeps gpt-4o/gpt-4o-mini; each override reaches the generator) + 2 new assertions in `test_llm_factory.py` (opus is identity in `direct`, `anthropic/claude-opus-4.8` in `openrouter`). Full offline suite **420 passed** (417 + 3), 1 skipped, 3 xfailed, 0 failed in ~66s.
- [x] **P1.2** RC-9: fix FactVerifier agreement so non-substring (estimation/reasoning) answers can pass; when search/judge unavailable, tag `unverified` + hold, don't drop at conf 0. *Gate:* a test proves a non-substring estimation answer is **not** dropped. ✅ **2026-06-23 (branch `ralph/overnight-20260623-1216`):** (1) **Agreement** — `fact_verifier.py` replaces the naive `answer_lower in content` with `_answer_supported()`: crisp/recall answers keep the **strict verbatim-substring** test, but numeric *estimation* answers now also agree when a source states the same magnitude within **±10%** (`_numbers_in()` parses comma-grouping + `thousand/million/billion/trillion` scale words, so "about 4 million" matches "4,000,000"). (2) **Hold-not-drop** — new `VerificationResult.held_for_review` flag; the **search-unavailable** (conf 0.0) and **judge-unavailable-without-agreement** branches now return verdict `unverified` + `held_for_review=True` instead of a drop-triggering low confidence. `VerificationStage` keeps held questions **regardless of confidence**, tagging `extra["held_for_review"]`/`verified=False`; non-held low-confidence (e.g. judge-available `likely_wrong`) **still drops** (strictness preserved). Scoped surgically: the no-results (0.2) and transient judge-exception (0.3) paths are left unchanged. *Gate met:* new `tests/verification/test_fact_verifier.py` (6 cases — numeric-tolerance agreement passes an estimate to `verified`; strict substring for recall; search/judge-unavailable → held) + a stage test proving a held low-confidence question is **kept** while an unheld one drops. Full offline suite **427 passed** (420 baseline + 7 new), 1 skipped, 3 xfailed, 0 failed in ~67s via `.venv/bin/python -m pytest tests/`.
- [x] **P1.3** MCQ crash isolation (`return_exceptions=True` + per-sub-batch try/except, `advanced_generator.py:396` = #42 task 42.31). *Gate:* unit test that one bad sub-batch doesn't sink the rest. ✅ **2026-06-24 (branch `ralph/overnight-20260624-1358`):** the per-pattern MCQ fan-out in `_generate_mcq_emphasis` now isolates failures at two layers — (1) `_one()` wraps the `_generate_mcq_batch_structured` call in `try/except Exception`, printing the failed pattern and returning `[]` so a flaky pattern drops only its own sub-batch; (2) the `asyncio.gather` gains `return_exceptions=True` as a belt-and-suspenders net, with the flatten guarded by `isinstance(batch, list)` so any surfaced exception is skipped instead of crashing the comprehension. Before this, the bare `gather` propagated the first failing coroutine and cancelled every sibling — one bad pattern (LLM timeout / malformed structured output) sank the whole MCQ order. *Gate met:* new `test_mcq_sub_batch_failure_does_not_sink_the_rest` makes the first sorted pattern raise and asserts (a) `generate_questions` does **not** raise, (b) all `len(patterns)` sub-batches were still attempted (no cancellation), and (c) the surviving count == requested minus the doomed pattern's share. Targeted suite `tests/generation/test_advanced_generator.py` **18 passed**; full offline suite **427 passed**, 1 skipped, 3 xfailed — the lone red, `test_order_sse_reconnect`, is a pre-existing SSE/arq timing flake that **passes in isolation** (verified this run), unrelated to this change.
- [x] **P1.4** Unlock the chosen MCQ reasoning pattern(s) in `PATTERNS_TO_MCQ` + recipes; broaden "comparison bet" via its recipe string (not a key rename). *Gate:* test the new pattern routes as decided. ✅ **2026-06-24 (branch `ralph/overnight-20260624-1358`):** per **decision #2**, unlocked **`order_of_magnitude`** — the driving-safe *bucketed* estimate — as the new fun MCQ reasoning pattern. (1) Added the key to `PATTERNS_TO_MCQ` (`pattern_routing.py`); it flows automatically into the activation section and the `--mcq-bias` footer, both of which derive from the set. The free-text `estimation` library label is deliberately **left out** of the set so text Estimation still routes to `text` (open numeric, decision #2) — only the explicit MCQ form goes `text_multichoice`. (2) Added its emission **recipe** in `advanced_generator.py` (four non-overlapping magnitude buckets a/b/c/d, `correct_answer` = the bucket's key letter) and flagged it as directly selectable in the bridging prose alongside `true_false`/`year_guess`, so the LLM actually picks it (root cause E). (3) **Broadened the comparison-bet recipe string** from the stale `older / larger / heavier` trio to `older / larger / heavier / faster / longer / closer / more populous / more valuable` — **via the recipe string only**, the canonical key `comparison_bet_older_larger` is unchanged (a rename would break the 42.20 alias contract). *Gate met:* `test_pattern_routing.py` — `order_of_magnitude` (+ title/spaced forms) routes to `text_multichoice`; `estimation` stays `text`; the set lock-test updated to 5 keys. `test_advanced_generator.py` — two new recipe-content tests prove the bucket recipe + selectability render and the comparison-bet recipe carries a new dimension. Targeted suite **114 passed**; full offline suite **435 passed**, 1 skipped, 3 xfailed, 0 failed in ~67s via `.venv/bin/python -m pytest tests/`.
- [x] **P1.5** Repair `OPEN_SHAPE_FRACTION` rounding so open questions aren't 0 on small orders. *Gate:* test ≥1 open question on a standard order. ✅ **2026-06-24 (branch `ralph/overnight-20260624-1358`):** `GenerationStage.run` computed `open_count = round(target_count * 0.04)`, which is **0 for every order up to 12 questions** — so the open/lateral branch (`question_generation_open.md`, 46.B4b) was **dead at the most common order size**, a standard 10-question pack. Fix: keep `round`'s proportional ~4% slice at scale but **floor the open count to 1 once the order is at least a standard pack** (new module constant `OPEN_SHAPE_MIN_ORDER = 10`); orders **1–9 still round to zero and stay entirely factual** (open is a ~4% minority shape — forcing 1/5 would be 20%, far above the target slice). Surgical: the floor only bites in the dead zone (10–12, which previously rounded to 0); 13+ already round to ≥1 naturally, so the proportional behaviour is untouched. *Gate met:* rewrote the now-inverted `test_default_open_fraction_keeps_small_orders_factual` (it asserted the buggy `10 → 0`) into two tests — `test_default_open_fraction_gives_standard_order_an_open_slice` proves a standard 10-order routes **≥1** open question (was 0), and `test_default_open_fraction_keeps_micro_orders_factual` proves a 5-order still routes **0** (the floor only applies at/above `OPEN_SHAPE_MIN_ORDER`). The explicit-fraction routing test (`open_fraction=0.5`, target 4 → 2) is unaffected (4 < 10 → plain `round(2.0)=2`). Targeted suite `tests/orchestrator/stages/test_generation.py` **23 passed**; full offline suite **436 passed** (435 baseline + 1 net new test), 1 skipped, 3 xfailed, 0 failed in ~77s via `.venv/bin/python -m pytest tests/`.

**Phase 2 — Lever B prompt restoration (read-only, no LLM)**
- [x] **P2.1** Backport the 471c41b engagement-path machinery (Patterns 11–13, Answerability, Engagement-Path principle, Structural-Monotony red flags) into the live `v3` prompt. *Gate:* prompt-content assertions. ✅ **2026-06-25 (branch `main`, founder interactive session — not the loop):** **Premise corrected (fail-loud).** The machinery was *not* "never backported to v3": `git show 471c41b` shows the **same commit** added it to **both** `v2_cot` **and** `v3_fact_first`. The live v3 prompt already contains every pillar — Patterns 11–13 (v3:93–95, abbreviated one-liners), the **Answerability** self-critique dimension (v3:67), the diversity rule "≥3 reasoning (7-13) / ≤4 recall (1-6)" + "Prefer patterns 7-13" (v3:81,97), the **Structural-Monotony** red flags (v3:112–114), Principle 5 **"Engagement Path over Dead End"** (v3:128), and the `answerability` JSON field (v3:245). So the content backport is **already satisfied**. The only genuine gap is the *depth* of Patterns 11–13 (v2_cot carries full Template/Examples/Key-rules/Why; v3 keeps one-liners) — **deliberately NOT expanded**: v3's Pattern Library is an intentional "Abbreviated Reference" for **all** 13 patterns, so enriching only 11–13 is stylistically inconsistent and verbose prose fights the brevity the rest of the fact-grounded v3 enforces. Offered to founder as optional follow-up **P2.1b**. *Gate met:* new `tests/generation/test_v3_prompt_engagement_machinery.py` (5 prompt-content assertions) locks the machinery into the live v3 prompt and **fails loudly if any pillar is stripped** — i.e. it would have caught the 2026-05-20-class silent regression. Non-DB offline suite **411 passed** incl. `tests/generation/` 156 (+5 new); the 25 `db/`+`api/orders`+`persist` failures are Postgres/Redis not running on this machine (#73 dev-stack lives on `mba`), unrelated to this prompt-only change — full green (441) is the gate machine's to confirm. **Signal for Phase 2+:** the machinery is *already live in v3* yet output stayed boring → the boring-ness is driven by the fact-first **lock** (dull source facts — RC-1/`6aa70b6`) and GPT-4o's weak creativity, **not** by missing patterns. This sharpens the real v3 levers to **P2.2** (escape hatch), **P3** (input fixes), and the **Lever-A** Opus swap at Phase 6.
- [x] **P2.2** Add the v3 escape hatch behind `V3_ESCAPE_HATCH` (fully revertible). *Gate:* prompt assertion gated by the flag. ✅ **2026-06-25 (branch `ralph/overnight-20260625-2200`):** the live v3 prompt's hard rule ("rely ONLY on source facts, never your own knowledge", v3:22) left no room for a surprising *angle* (RC-5) — a direct cause of "prvoplánové" output. Added a dormant escape hatch wired off the P0.2 `feature_flags.v3_escape_hatch()` flag: (1) a new `{escape_hatch_section}` placeholder **appended inline** to the SOURCE-FACTS instruction in `question_generation_v3_fact_first.md` — appended (not on its own line) so the empty default leaves the prompt **byte-identical** to today; (2) an empty `"escape_hatch_section": ""` default in `prompt_builder.py` (exact `mcq_patterns_section` precedent) so all four prompt templates render unconditionally; (3) `_build_batch_prompt` fills it with the module constant `_V3_ESCAPE_HATCH_SECTION` **only when the flag is on**. The hatch loosens the *framing* (allow an angle/comparison/"aha" from general knowledge) but **keeps the answer grounded** — "the core factual claim … still traces to one of the source facts above", "never for the *answer*" — so it never reverts to the do-NOT-retry "pure-imagination generation". *Gate met:* new `tests/generation/test_v3_escape_hatch.py` (4 cases) — flag-off → no hatch text + SOURCE FACTS still present; flag-on → hatch present; hatch keeps the grounding clause; and a **revertibility proof** that removing the section from the flag-on prompt yields the byte-identical flag-off prompt (built through the v3 `PromptBuilder` with the two randomly-sampled sections pinned). Offline suite `tests/generation/` + `tests/test_feature_flags.py` + `tests/orchestrator/stages/test_generation.py` = **198 passed, 0 failed** (incl. v2_cot/default/open paths, which ignore the unused extra key). DB/api/persist tests need Postgres/Redis (#73 stack on `mba`), unrelated to this prompt-only change — full green is the gate machine's to confirm.
- [x] **P2.3** Thread `question_type` into few-shot loading so MCQ batches see MCQ exemplars (answer-stripped). *Gate:* exemplar-count/schema test. ✅ **2026-06-25 (branch `ralph/overnight-20260625-2200`):** the gap was precise — `prompt_builder.build_prompt` already *knows* `question_type` (param since #42) but at line 67 called `load_gold_standard(n, topics, difficulty)` **without it**, so every batch (incl. MCQ) drew a type-blind random sample. RC-8: the library is **3/53 MCQ**, so an n=5 draw usually surfaced **zero** MCQ exemplars — the LLM saw no `possible_answers` option-dict shape for the very batch that needs it (the pre-existing `test_load_gold_standard_renders_mcq_options_inline` had to *re-roll up to 20×* to find one). Fix: (1) `load_gold_standard` gains an opt-in `question_type` param; when `text_multichoice`, it biases the pool toward MCQ exemplars **first** (before topic/difficulty), mirroring the topic filter's filter-then-top-up so a batch is never starved — the later topic/difficulty top-ups draw from the MCQ-biased pool so MCQ examples survive; non-MCQ types fall through byte-identically (dormant for the dominant text path). (2) Threaded `question_type=question_type` at the call site. Answer-stripping for trailing pattern-only exemplars is unchanged (existing `full_count` logic). *Gate met:* `test_gold_standard_mcq.py` — `test_mcq_question_type_surfaces_mcq_exemplars_deterministically` proves all available MCQ exemplars render on **every** roll (15×, count == `min(num_mcq, n)`) with the option shape + preserved answer-omit note, and **fails loudly if the threading is dropped**; `test_question_type_text_leaves_sampling_unbiased` proves the text path stays type-blind (bias gated on `text_multichoice` only). `tests/generation/` **162 passed**, 0 failed in ~3s. DB/api/persist tests need Postgres/Redis (#73 stack on `mba`), unrelated to this prompt-only change — full green is the gate machine's to confirm.

**Phase 3 — input fixes under mocks (no real network)**
- [x] **P3.1** RC-1: OpenTDB → bare declarative fact (cheap-model rewrite) with a guard asserting output never contains the original-question substring. *Gate:* respx `assert_all_mocked=True`; guard test. ✅ **2026-06-25 (branch `ralph/overnight-20260625-2200`):** `_extract_fact` still emits the re-wrap `The answer to '<question>' is <answer>.` (RC-1) — left **byte-identical** as the dormant default. Added (1) `OpenTriviaFactRewriter`, a cheap-model (`gpt-4o-mini`) rewriter mirroring `AnswerNormalizer` exactly — lazy `llm_factory` client (#53 contract, no SDK at call site), `_available()` gate, **fail-safe `None`** on any unavailability/exception/empty; (2) module-level guard `_fact_echoes_question()` (case-insensitive full-question substring test, **strips trailing `?`** so a rewrite that merely drops the mark is still caught); (3) an injectable `OpenTriviaDBSource(rewriter=None)` + new async `_build_fact` that, **only when a rewriter is set**, replaces the text with the declarative rewrite and **drops the seed** (returns `None`) when the rewrite is absent/empty or fails the guard — so an *active* source can never emit a re-wrap. Dormant by default (nothing wires a rewriter yet; `FactSourcer` constructs `OpenTriviaDBSource()` no-arg → unchanged). *Gate met:* new `tests/sourcing/test_opentriviadb_rewrite.py` (9 cases) — 4 respx tests (`@respx.mock(assert_all_mocked=True)`, host+path match so a real opentdb.com call fails loudly): dormant byte-identical re-wrap; active rewrite emits the declarative + guard passes; an echoing rewrite is **dropped**; unavailable rewriter drops; + 3 guard unit tests (incl. trailing-`?`) + 2 no-network rewriter fail-safe tests. `tests/sourcing/` **14 passed**; `tests/orchestrator/` **61 passed**, 0 failed (no regression). DB/api/persist tests need Postgres/Redis (#73 stack on `mba`) — full green is the gate machine's to confirm.
- [x] **P3.2** Wire `top_by_surprise()` + a free heuristic surprise score (no per-fact LLM). *Gate:* unit test the ordering/score. ✅ **2026-06-25 (branch `ralph/overnight-20260625-2200`):** RC-2 — every source stamped a flat fabricated `surprise_rating` and `top_by_surprise()` had **zero call sites**, so the prompt's "prefer surprising facts" was a no-op. (1) Added `heuristic_surprise(text)` to `sourcing/models.py`: a free, deterministic score (no LLM/network) from cheap signals — superlative/extreme markers (`largest`/`only`/`never`/… ; +1.5 each, capped at 3 so adjectives can't run away), a concrete number (+1.0), and a **−2.0 penalty** for the OpenTDB re-wrap shape ("The answer to '…' is …", RC-1). Baseline 4.0 puts plain recall facts just under the prompt's "surprise ≥ 5" line; extreme/quantified facts clear it. Clamped to [1,10]. (2) Added `FactBatch.score_surprise_heuristic()` (mutates ratings in place, returns self for chaining). (3) **Wired the live call site** in `SourcingStage.run`: `batch.score_surprise_heuristic()` then `ctx.facts = batch.top_by_surprise(len(batch.facts))` — **ordering only** (n = all facts), so the 2× dedup headroom downstream is preserved; facts are just surprise-first so generation anchors on the interesting ones (and the first-with-url `fallback_fact` becomes the most surprising sourced fact). *Gate met:* new `tests/sourcing/test_surprise_scoring.py` (4 cases — extreme > plain > re-wrap tiers; marker cap + [1,10] bounds; method replaces the flat default + is chainable; `score → top_by_surprise` orders most-surprising-first and drops the dull tail) + a live-wiring test in `test_sourcing.py` (`test_facts_emerge_surprise_ranked`: an OpenTDB re-wrap sinks below an extreme fact in `ctx.facts`, count preserved). Offline `tests/sourcing tests/orchestrator tests/generation` = **274 passed, 0 failed** (50 + 224; incl. integration http-mock paths). DB/api/persist tests need Postgres/Redis (#73 stack on `mba`) — full green is the gate machine's to confirm.

**Phase 4 — scoring veto as SHADOW (deterministic mocks)**
- [x] **P4.1** Wire the Answerability/surprise veto into the live scorer with `critique_v2` anchors in `VETO_SHADOW` mode (log would-drops, drop nothing). *Gate:* a starboard-class recall Q is flagged in shadow on synthetic fixtures, with no false-veto of the good ones. ✅ **2026-06-25 (branch `ralph/overnight-20260625-2200`):** RC-10/11 — fun was measured in ~5 places and enforced in 0. Wired a deterministic Answerability/surprise veto into `ScoringStage` (`scoring.py`), consulted **only** when the dormant P0.2 `feature_flags.veto_shadow()` flag is on (`from app import feature_flags`, matching the file's absolute-import style). (1) New module fns `_shadow_veto_reason()`/`_mean_dim()` flag the "starboard-class" boring dead-end recall Q when **both** the surprise and answerability signals are mean ≤ **3.0** (`VETO_SURPRISE_MAX`/`VETO_ANSWERABILITY_MAX`) — a **logical AND** so a merely-unsurprising estimation Q or a surprising-but-dead-end Q is never falsely vetoed. Thresholds calibrated to the `question_critique_v2` anchors: "Poor 3-4" boring-recall sits at surprise 2 / answerability 2 (flagged); "Average 5-6 meets minimum bar" sits at surprise 5 / framing 4 (kept). Dual alias tuples (`surprise_factor`/`surprise_delight`, `answerability`/`clever_framing`) read whichever rubric the scorer emitted — the live `SCORING_PROMPT` (delight/framing) or `critique_v2` (factor/answerability) — so it works under either. (2) In `run()`, shadow mode **logs + counts** would-drops (`veto_shadow_flagged` in `StageResult.info`, mirroring `dropped_low_score`) and **keeps every question** — independent of the score gate, so a boring Q that clears the lenient 3.0 floor is still flagged. Dormant by default (flag off → veto never consulted; the empty-questions early return is left byte-identical). *Gate met:* `test_scoring.py` — `test_shadow_veto_reason_flags_starboard_class_recall` (pure-fn: starboard (2,2) flagged; exceptional (9,8), minimum-bar (5,4), surprising-dead-end (8,2), and unscored all kept), `test_veto_shadow_flags_starboard_class_but_keeps_it` (flag on → starboard Q flagged in `info` yet **not dropped**, good Q not flagged), `test_veto_dormant_when_flag_off` (default → zero flags). `tests/orchestrator/stages/test_scoring.py` + `tests/test_feature_flags.py` **24 passed**; `tests/orchestrator` **65 passed**, 0 failed. DB/api/persist tests need Postgres/Redis (#73 stack on `mba`), unrelated to this scorer-only change — full green is the gate machine's to confirm.
- [x] **P4.2** Restore MCQ-path best-of-N + `self_critique` telemetry. *Gate:* unit test the MCQ critique path runs. ✅ **2026-06-25 (branch `ralph/overnight-20260625-2200`):** RC-7 — the text best-of-N path stamps a `critique_score` per question, but the per-pattern MCQ sub-batch path (`_generate_mcq_sub_batches`) recorded **none**, so MCQ "fun" was measured in **0 places**. Wired the self_critique judge into the MCQ path as **telemetry**, dormant behind a new P0.2-style flag `feature_flags.mcq_critique_telemetry()` (`MCQ_CRITIQUE_TELEMETRY`, default off): when on, after the sub-batches are collected it runs `_critique_question` **once per kept question** and merges the critique into provenance (`critique_score`/`critique_model` + the full dict into `extra`), mirroring the text best-of-N annotation (lines 307–317) **but dropping nothing**. Deliberately **NOT** best-of-N over-generation — asking for `count*n_multiplier` (~57) in one call is the yield collapse this sub-batch path replaced (issue "Do NOT retry"); `ScoringStage` stays the ship gate. Dormant by default → output byte-identical to today (the existing MCQ fan-out/crash-isolation/partition tests are unchanged). *Gate met:* `test_mcq_critique_telemetry_annotates_each_question_when_flag_on` (flag on → judge awaited exactly once per kept question, every question survives, each gets `critique_score`/`critique_model` + merged `verdict` without clobbering the `stage` marker) + `test_mcq_critique_telemetry_dormant_when_flag_off` (default → **zero** critique calls, `critique_score is None`). `tests/generation` + `tests/test_feature_flags.py` **37 passed**; `tests/generation tests/orchestrator` **229 passed**, 0 failed in ~9s. DB/api/persist tests need Postgres/Redis (#73 stack on `mba`), unrelated to this generation-only change — full green is the gate machine's to confirm.

**Phase 5 — validation harness, dormant (no LLM)**
- [x] **P5.1** `scripts/validate_generation.py`: asserts machine-checkable quality proxies across all types; guard so it can **never** write to the corpus. *Gate:* harness unit-tested on synthetic data; dry-run shape OK. ✅ **2026-06-25 (branch `ralph/overnight-20260625-2200`):** new `scripts/validate_generation.py` scores a batch of generated `Question`s against seven **pure, importable** quality proxies — `non_empty` (no-crash stand-in), `non_recall_per_type` (≥1 reasoning pattern 7-13 per question type present), `pattern_diversity` (≥3 distinct reasoning patterns), `no_banned_openers` (zero "What is the capital…/Who wrote…/What year did…/Which author…", the documented `v2_cot` red flags), `which_opener_fraction` (≤30% "Which"), `mcq_valid` (option dict + correct key ∈ options + ≥1 distinct distractor, no blank/dup values), and `answer_brevity` (the **spoken** answer ≤6 words — resolves an MCQ key→option-value so a letter isn't mistaken for a short answer). Pattern taxonomy mirrors the issue: `order_of_magnitude`/`year_guess` count as reasoning (P1.4), `true_false` as recall (RC-6 complement). **Corpus-write guard:** the flow is built via `generate_pack`'s own `_build_stages(persist=False, …)`/`_build_order`/`_build_dedup_store("noop")` (byte-identical to prod minus PersistStage) and `assert_no_corpus_write()` raises if any persisting stage (`name=="persisting"` or class `PersistStage`) slips in — so the harness **can never write the corpus** (the #72 stop condition). No LLM/DB/network in the harness itself; the paid run is the founder's Phase-6 step. *Gate met:* new `tests/scripts/test_validate_generation.py` (29 cases) — every proxy pass+fail on synthetic `Question.from_dict` fixtures, a keystone "clean batch passes all 7", the guard (raises on a stand-in persister, passes on a clean list), and **dry-run shape OK** (`build_dry_run_stages()` constructs the real `generate_pack` stages **offline**, asserts `sourcing` first + zero persisters). `tests/scripts/` **94 passed**, 0 failed in ~4s via `.venv/bin/python -m pytest tests/scripts/`. DB/api/persist tests need Postgres/Redis (#73 stack on `mba`), unrelated to this script-only change — full green is the gate machine's to confirm.

🛑 **Phase 6 — STOP. Not a Ralph task.** The single founder-authorized validation run (~$5) and the founder's by-ear judgment (6b) are a **human checkpoint**. When every box above is checked and the suite is green, **Ralph is done** — leave everything dormant behind toggles, push the `ralph/*` branch, and stop. Un-park is the founder's call; Ralph must never start a paid generation run to "finish" this issue.

**✅ Ralph-complete (2026-06-25, branch `ralph/overnight-20260625-2330`):** every Phase 0–5 box above is
checked **and** the full offline suite is verified green **first-hand — 495 passed, 1 skipped (Apple-root,
setup-gated), 3 xfailed (worker stubs), 0 failed** in ~56s via `.venv/bin/python -m pytest tests/` (Postgres
+ Redis up, #73). This **closes every prior phase note's "full green is the gate machine's to confirm."**
**The Ralph stop condition is MET — Ralph is done.** Everything ships dormant behind toggles
(`GENERATION_MODEL`, `V3_ESCAPE_HATCH`, `VETO_SHADOW`, `MCQ_CRITIQUE_TELEMETRY`); **PARKED awaiting the
founder's Phase-6 un-park** (the one paid validation run + the 6b by-ear judgment). Ralph must not cross the 🛑 line.

## Decisions I made for you (override any)

Per *"nemusíš so mnou riešiť detaily, sám vieš väčšinou lepšie rozhodnúť"*, the old 7 open questions are
resolved and baked in:
1. **Corpus scoring pass — dropped entirely** (it's corpus-eval, which you de-scoped).
2. **Estimation routing:** default to **open free-text numeric estimate** for text; add **bucketed
   order-of-magnitude** as the new fun MCQ pattern. (Driving-safe + adds an MCQ reasoning pattern.)
3. **Scorer:** **add** the Answerability veto dimension to the existing scorer (lower-risk) rather than
   swapping the whole 6-dim contract.
4. **"Angle-first" root inversion:** folded into Lever B's escape hatch rather than a separate large rewrite;
   a deeper angle-first architecture stays a later optional bet.
5. **Model:** lock **`claude-opus-4-8`** as the creative-gen default; Fable 5 A/B optional, only if Opus output still feels flat.
6. **`gold_standard.json`** factual audit stays a small code/data check (verify before reusing any exemplar).

## Do NOT retry (tried & failed / already shipped)

- In-prompt self-critique **as the gate** — self-scored, inflatable; it *is* the status quo that produced boring output.
- Pure-imagination generation with no source grounding — reintroduces the hallucination risk v3 was built to remove.
- Asking GPT-4o for ~57 questions in one call (returns 4–10) — the per-pattern sub-batch architecture is the shipped fix.
- Re-pitching MCQ routing/normalization (snake_case keys, `the_`-strip, alias map, `mcq_emphasis`) — shipped (#42 A/B/D/E).
- Re-enabling topic-agnostic Wikipedia DYK on themed orders — reverts #42 task 42.28.
- Re-litigating Tavily vs SearXNG/Brave/Firecrawl — settled (keep Tavily PAYG).

## Acceptance

> **Ralph stop condition (machine-evaluable, offline):** when every Phase 0–5 box in the task list is
> checked and the offline suite is green, **Ralph's goal is met — stop cleanly and push the `ralph/*` branch.**
> The bullet tagged *(human)* below is the founder's Phase-6 un-park gate; Ralph must **never** attempt a paid
> generation run to satisfy it, and reaching it does not count as a Ralph failure.

- **Phases 0–5 green offline with ZERO paid generation**; each gate labelled *plumbing-correct, not fun-validated*.
- **Lever A:** generation model is config-driven and defaults to `claude-opus-4-8` via OpenRouter remap (dormant until Phase 6).
- **Lever B:** the 471c41b engagement-path machinery is live in the `v3` path; the escape hatch is toggle-guarded and revertible.
- **RC-9 lands before any gate tightening** — a test proves a non-substring estimation answer survives the verifier.
- A starboard-class recall question is **flagged** by the wired veto in `VETO_SHADOW` on synthetic fixtures (fun enforced in ≥1 place in plumbing).
- *(human)* The Phase-6 run produces, **across all types**, output that (a) doesn't crash, (b) includes ≥1 working non-recall pattern per type, and (c) the founder judges **less boring by ear (6b)**. Un-park requires 6b — no proxy substitutes. **This is the founder's gate, not Ralph's.**
- No corpus writes occur until the founder un-parks; everything ships dormant/behind a toggle otherwise.

## Links

- Evidence + ranked solutions: `docs/artifacts/question-quality-fun-review-2026-06-22.html`
- Research this turn (refocus): workflow `wf_436834d9-e21` (4 streams — current arch · 2026-05-20 archaeology ·
  OpenRouter model research · sibling-issue cleanup); Claude model facts grounded via the `claude-api` skill;
  top-level first-hand spot-checks (v2/v3 lock `advanced_generator.py:520`; scoring models `multi_model_scorer.py:186,193`;
  RC-1/RC-9; `PATTERNS_TO_MCQ`; old Claude gen script is git-historical only).
- Complements: MCQ structural survival = [[issue-42-question-quality-and-mcq]] Track F-R (task 42.30 = ≥8/10 MCQ
  yield gate). New-content growth = [[issue-30-batch-generate-categories]] (**deferred**, founder-owned, post-#72).
  Worker/dedup infra prerequisites for the Phase-6 run = #70. Generation audit record = [[issue-63-question-quality-review]]
  Track A (Track B corpus verification de-scoped per founder).
- Prior engagement work: `docs/archive/data-tasks/ENGAGEMENT_PATH_FOLLOWUP.md`.

<!-- obsidian-links:start -->
## Súvisiace issues
[[issue-42-question-quality-and-mcq|#42 Question quality sweep + multichoice activation]] · [[issue-63-question-quality-review|#63 Question-quality review: generation audit + corpus verification]] · [[issue-30-batch-generate-categories|#30 Batch-generate questions for new categories]]
<!-- obsidian-links:end -->


## BLOCKER (2026-06-26) — plan-readiness pre-flight (NOT-READY)

- The readiness gate (#57 57.13) refused to start an autonomous run on this issue: ready-check produced no parseable READY_VERDICT (see /Users/agent/code/quiz-agent/scripts/ralph/logs/ready-20260626-000008.log)
- No iteration ran; the branch was NOT pushed. Verifying the loop output cannot rescue an unready input (garbage in, garbage out).
- Next human-touch: clear the Definition-of-Ready (`/triage` C1–C7: add the `## Acceptance` block, declare `**Reversibility:**`, run `/ready-check`), then re-run. Override only by setting `RALPH_READYCHECK=0` for a deliberate exception.

### RESOLUTION (2026-06-26, branch `ralph/overnight-20260626-0100`) — BLOCKER was a FALSE NEGATIVE, no action needed

The NOT-READY verdict above is **spurious** — the ready-check didn't fail on plan content, it failed because the
Claude **session usage-limit** was hit. The referenced log
(`scripts/ralph/logs/ready-20260626-000008.log`) contains a single line:
`You've hit your session limit · resets 12:30am (Europe/Prague)` — i.e. ready-check got a rate-limit message
instead of a READY_VERDICT, and the gate mislabeled that as NOT-READY. **Garbage gate-output, not a garbage plan.**

The BLOCKER's own prescribed remediation is **already satisfied in this file**:
- `## Acceptance` block — **present** (line ~260, with the machine-evaluable Ralph stop condition).
- `**Reversibility:**` — **declared** (line 5, `a · commits-only`).

And the issue is in fact **Ralph-complete**: all 15 Phase 0–5 boxes are `[x]`, the full offline suite was verified
green first-hand (**495 passed / 0 failed**, see the 2026-06-25 Ralph-complete note above), and `67a99e3`
(Ralph-complete) landed *before* `6a445a7` (this BLOCKER) — the gate ran against an issue that was already done.
**Phase 6 is the 🛑 founder-only checkpoint; there is no Ralph-actionable work left here.**

**No human-touch required to "fix readiness."** If a verdict is ever needed again, re-run ready-check after the
session limit resets (or set `RALPH_READYCHECK=0`). Otherwise this issue stays **PARKED for the founder's Phase-6
un-park** — Ralph must not pick it up or cross the 🛑 line.

## BLOCKER (2026-06-27) — plan-readiness pre-flight (NOT-READY)

- The readiness gate (#57 57.13) refused to start an autonomous run on this issue: issue is already Ralph-complete (all Phase 0–5 boxes [x]); Phase 6 is a founder-only human checkpoint Ralph must never cross.
- No iteration ran; the branch was NOT pushed. Verifying the loop output cannot rescue an unready input (garbage in, garbage out).
- Next human-touch: clear the Definition-of-Ready (`/triage` C1–C7: add the `## Acceptance` block, declare `**Reversibility:**`, run `/ready-check`), then re-run. Override only by setting `RALPH_READYCHECK=0` for a deliberate exception.
