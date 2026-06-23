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
- [ ] **P0.2** Add dormant flags (`GENERATION_MODEL`, `V3_ESCAPE_HATCH`, `VETO_SHADOW`, …); do **not** flip `LLM_GATEWAY` repo-wide. *Gate:* suite green, output unchanged with flags off.

**Phase 1 — Lever A wiring + deterministic fixes (no LLM)**
- [ ] **P1.1** Make generation/critique models config-driven; add `claude-opus-4-8` to `_REMAP_OPENROUTER` (dormant default, never hardcode at call site). *Gate:* unit test on config resolution.
- [ ] **P1.2** RC-9: fix FactVerifier agreement so non-substring (estimation/reasoning) answers can pass; when search/judge unavailable, tag `unverified` + hold, don't drop at conf 0. *Gate:* a test proves a non-substring estimation answer is **not** dropped.
- [ ] **P1.3** MCQ crash isolation (`return_exceptions=True` + per-sub-batch try/except, `advanced_generator.py:396` = #42 task 42.31). *Gate:* unit test that one bad sub-batch doesn't sink the rest.
- [ ] **P1.4** Unlock the chosen MCQ reasoning pattern(s) in `PATTERNS_TO_MCQ` + recipes; broaden "comparison bet" via its recipe string (not a key rename). *Gate:* test the new pattern routes as decided.
- [ ] **P1.5** Repair `OPEN_SHAPE_FRACTION` rounding so open questions aren't 0 on small orders. *Gate:* test ≥1 open question on a standard order.

**Phase 2 — Lever B prompt restoration (read-only, no LLM)**
- [ ] **P2.1** Backport the 471c41b engagement-path machinery (Patterns 11–13, Answerability, Engagement-Path principle, Structural-Monotony red flags) into the live `v3` prompt. *Gate:* prompt-content assertions.
- [ ] **P2.2** Add the v3 escape hatch behind `V3_ESCAPE_HATCH` (fully revertible). *Gate:* prompt assertion gated by the flag.
- [ ] **P2.3** Thread `question_type` into few-shot loading so MCQ batches see MCQ exemplars (answer-stripped). *Gate:* exemplar-count/schema test.

**Phase 3 — input fixes under mocks (no real network)**
- [ ] **P3.1** RC-1: OpenTDB → bare declarative fact (cheap-model rewrite) with a guard asserting output never contains the original-question substring. *Gate:* respx `assert_all_mocked=True`; guard test.
- [ ] **P3.2** Wire `top_by_surprise()` + a free heuristic surprise score (no per-fact LLM). *Gate:* unit test the ordering/score.

**Phase 4 — scoring veto as SHADOW (deterministic mocks)**
- [ ] **P4.1** Wire the Answerability/surprise veto into the live scorer with `critique_v2` anchors in `VETO_SHADOW` mode (log would-drops, drop nothing). *Gate:* a starboard-class recall Q is flagged in shadow on synthetic fixtures, with no false-veto of the good ones.
- [ ] **P4.2** Restore MCQ-path best-of-N + `self_critique` telemetry. *Gate:* unit test the MCQ critique path runs.

**Phase 5 — validation harness, dormant (no LLM)**
- [ ] **P5.1** `scripts/validate_generation.py`: asserts machine-checkable quality proxies across all types; guard so it can **never** write to the corpus. *Gate:* harness unit-tested on synthetic data; dry-run shape OK.

🛑 **Phase 6 — STOP. Not a Ralph task.** The single founder-authorized validation run (~$5) and the founder's by-ear judgment (6b) are a **human checkpoint**. When every box above is checked and the suite is green, **Ralph is done** — leave everything dormant behind toggles, push the `ralph/*` branch, and stop. Un-park is the founder's call; Ralph must never start a paid generation run to "finish" this issue.

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
