# Issue #72 — Question fun/engagement redesign (anti-"prvoplánové")

**Triage:** enhancement · ready-for-human (founder-in-the-loop; un-park decision feeds #63/#42)

**Created:** 2026-06-22 · **Founder:** Michal

## Why

Founder-flagged 2026-06-22: just-generated MCQs were too fact-based / boring ("prvoplánové" =
first-degree plain recall), e.g. *"What term do sailors use for the right side of a vessel? →
Starboard"*. Founder hypothesis: it's a **prompt-engineering + source-finding** problem.

This issue is the **fun/engagement** half of the question-quality effort. It is distinct from:
- [[issue-42-question-quality-and-mcq]] **Track F-R** = MCQ *structural survival* (does the model emit
  a valid `text_multichoice` contract at all — the 1/10–2/13 yield defect).
- [[issue-63-question-quality-review]] = the parked *audit* that gates the un-park decision.

#72 owns the orthogonal question: even when generation *works*, **why are the questions dull, and
how do we make them fun** — the concern the founder has raised "veľakrát predtým".

Full evidence + research + ranked solutions (visual): **`docs/artifacts/question-quality-fun-review-2026-06-22.html`**.

## Diagnosis (verified)

**The pipeline is a boring-question amplifier**: it generates recall-biased questions, then
preferentially *keeps* the recall ones. Fun is measured in five places and **enforced in zero**.

**One acute cause** (already mitigated) + **structural causes** (persist with Tavily up):

- **Acute:** Tavily (the only source that actively searches for surprising material) was over-quota
  → pipeline collapsed onto OpenTriviaDB, whose fact extraction re-wraps each trivia *question* as
  the "fact" (`opentriviadb_source.py:98` — `"The answer to '{question}' is {answer}."`), so the v3
  "transform, don't rephrase" instruction has nothing to transform and the model re-asks it. **This
  is the literal starboard mechanism.** Tavily now topped up ($10 PAYG). *Recovery fraction is an
  unconfirmed hypothesis — Phase 0 measures it.*

- **Structural root causes** (RC numbers map to the HTML report):
  - **RC-1** OpenTDB re-embeds the question as the fact. `opentriviadb_source.py:98` ✓ verified
  - **RC-2** `surprise_rating` is fabricated everywhere (OpenTDB difficulty map `:101`; Tavily hard-codes
    `6.0` `web_search_source.py:61`; Wikipedia flat `5.0`); `FactBatch.top_by_surprise()` exists but is
    never called → the prompt's "Surprise ≥ 5 preferred" filter is a no-op. ✓ verified
  - **RC-3** Tavily reach is throttled (`queries_per_topic = max(1, count // n_topics)` `:32`) and only 2
    generic templates (`:35-38`). ✓ verified
  - **RC-4** Wikipedia returns dry search snippets, not facts; the DYK/featured path is bypassed when
    topics are supplied. `wikipedia_source.py:34-50,174-184`
  - **RC-5** v3 fact-first prompt has **no escape hatch** for a surprising angle — every question is
    hard-chained to whatever the (often dull) source says. `question_generation_v3_fact_first.md:22` ✓ verified
  - **RC-6** The 4 MCQ patterns (`true_false, odd_one_out, comparison_bet_older_larger, year_guess`) are
    the strict *complement* of the fun reasoning patterns; Estimation/Reverse/Lateral are locked out of
    MCQ. `pattern_routing.py:23-30` ✓ verified
  - **RC-7** MCQ path skips best-of-N critique; `MCQQuestionItem` schema strips `self_critique`.
    `advanced_generator.py:353-356,31-65`
  - **RC-8** Few-shot library is type-blind (~3/53 examples are MCQ; `odd_one_out` has zero); GPT-4o also
    copies examples verbatim. `examples.py:49`, `prompt_builder.py:67`
  - **RC-9** FactVerifier agreement is naive substring (`agrees = answer_lower in content`
    `fact_verifier.py:89`); crisp recall answers match verbatim & pass, estimation/reasoning answers
    don't → dropped at the 0.5 gate. **Verification selects *for* boring.** ✓ verified
  - **RC-10** Only live gate is `MIN_OVERALL_SCORE = 3.0` (`scoring.py:44`, "deliberately lenient"); the
    calibrated `question_critique_v2` Answerability/dead-end veto is advisory-only, never wired. ✓ verified
  - **RC-11** In-prompt self-critique is soft/inflatable (Answerability is 5th of 5 equal dims, keep-if-avg-≥8).

## Constraints / decisions carried in

- **🔒 FOUNDER MANDATE (2026-06-22): NO generation re-run until the flow is reworked AND excellent.**
  Verbatim: *"nechcem ziadny re-run spustat kym nie je flow generovania otazok upraveny a vynikajuci."*
  This **forbids** the old "Phase 0 = run once to validate Tavily" opener and forces **offline-first**
  sequencing: build everything dormant, validate offline as far as honestly possible, and spend **exactly
  one** confirming run at the very end as the un-park gate. See `## Plan (offline-first)` below.
- **🎯 Honest boundary (adversarial review): offline-green ≠ fun.** No offline phase measures the founder's
  real signal ("prvoplánové" felt while listening hands-free). Every pre-final gate proves
  **PLUMBING-CORRECT, NOT FUN-VALIDATED.** The only true arbiter of "less boring" is the founder's ear on
  the final run's output — a **human-listen step is mandatory** at the end.
- **🧩 The existing corpus has ZERO `text_multichoice`** — 580 = 550 text + 25 image + 5 true_false (#63
  Track B). #72 is an MCQ problem, so offline shadow-scoring/calibration runs on **non-MCQ data**: it
  validates the scorer's *text-domain* sense only. **MCQ-specific thresholds + effect are inherently
  deferred to the final run.** Do not claim MCQ thresholds were calibrated offline.
- **OpenRouter key is PRESENT** (verified 2026-06-22, len 73); `LLM_GATEWAY` is **unset → direct mode**.
  Setting `LLM_GATEWAY=openrouter` unlocks the 2nd scorer (Claude) + Gemini verify **without**
  GOOGLE/ANTHROPIC keys. It is a **global** toggle (affects verify + generation) — **do not flip it
  repo-wide at baseline**; scope it to the scoring/gate path or set it only at the final gate.
- **Generation stays PARKED** (founder, 2026-06-12) — nothing here writes to the corpus until un-park.
  Everything is **built + offline-tested** now; the single paid run (final phase) is the un-park gate.
- **Fix supply BEFORE raising the gate.** Raising the floor on a starved sourcing layer drops yield to
  ~zero. Sequence: supply → floor → conversion → premium sources.
- **Nothing here has run against real gpt-4o** (cost + park + the known MCQ crash). Magnitudes are
  hypotheses until the final confirming run; offline phases prove correctness, not effect.
- **Sources:** keep Tavily (PAYG ok); **reject** SearXNG self-host, Brave, Firecrawl, Reddit API
  ($12k/yr), Wikidata SPARQL (produces more "which is bigger" recall). (memory: web_search_provider.)
- **No `'haiku'` model id exists in the repo** — use `factory.chat_openai('gpt-4o-mini')` for any rewrite
  step (adversarial pass caught a proposed `chat_openai('haiku')` that would crash).

## Plan (offline-first)

> **Resequenced 2026-06-22** per the founder mandate (no run until the flow is excellent). The old plan
> opened with a paid validation run — that is now **forbidden**. Principle: build dormant → validate offline
> on the **offline validation ladder** (Rungs 0–6 = Phases 0–6) → spend **one** confirming run (Phase 7) as
> the un-park gate. **Every Phase-0–6 gate proves PLUMBING-CORRECT, NOT FUN-VALIDATED** (see Constraints).
> Task IDs (72.x) are unchanged; only their order + framing changed. Three adversarial corrections are baked
> in: **72.13 (RC-9) moves UP before 72.8**; the **72.8-vs-72.12 estimation routing conflict** must be
> resolved before its locking test; **72.15 is explicitly deferred, not dropped**.

### Phase 0 — Baseline green + dormant flags (no LLM, no run)
- Confirm the existing suite is green offline (139 tests, ~0.84s).
- Add all new behaviour behind **dormant feature flags** (`VETO_SHADOW`, escape-hatch toggle, etc.) so
  nothing changes pipeline output until explicitly enabled.
- **Do NOT** flip `LLM_GATEWAY` repo-wide here (global; affects verify + generation) — scope it to the
  scoring/gate path, or set it only at the Phase-7 gate.
- *Gate:* suite green, flags dormant. **Plumbing only.**

### Phase 1 — Deterministic code fixes (no LLM, no corpus)
- **72.0a** (RC, crash) MCQ crash isolation: `return_exceptions=True` + per-sub-batch try/except at
  `advanced_generator.py:396`; make `_generate_mcq_batch_structured` (`:651-669`) tolerant of
  non-conforming items. (= #42 task 42.31 — do here or there, link it.)
- **72.13** (RC-9) **[MOVED UP — must precede 72.8]** FactVerifier agreement is naive substring
  (`fact_verifier.py:89`); it silently drops exactly the new estimation/reverse answers (they don't match
  verbatim). Fix the agreement logic so non-recall answers can pass, AND when search/judge is unavailable
  **tag `unverified` + hold for review** instead of dropping at confidence 0. Keep verification **strict**
  for crisp factual answers. Do **not** re-architect — mode routing shipped in #46.
- **72.8** (RC-6) Add the new fun MCQ pattern(s) to `PATTERNS_TO_MCQ` with their own recipes — **only after
  resolving the routing conflict in Open Q #2** (estimation as open free-text vs bucketed-MCQ). Keep
  `lateral` free-text. Broaden "comparison bet" via its recipe string (`:815`), **not** a key rename.
- **72.11a/c** (RC-8) Thread `question_type` into `load_gold_standard` (`examples.py:49`,
  `prompt_builder.py:67`) so MCQ batches see MCQ examples; keep exemplars **answer-stripped/structural**.
- **72.12a** Voice/driving constraint text: cap MCQ at 2–3 spoken options, options at end of stem, ~15-word
  stems. (The estimation-routing half, 72.12b, is gated on Open Q #2.)
- *Gate:* unit tests green offline (incl. a test proving a non-substring estimation answer is **not**
  dropped by 72.13, and that 72.8's new pattern routes as decided). **Plumbing only.**

### Phase 2 — Static prompt/data audits (read-only, no LLM)
- **72.10** (RC-5) Prompt escape hatch (allow a surprising *angle* from general knowledge as long as the
  factual *claim* traces to source) + "Assumption-Flip" pattern + misconception-distractor rule. **Highest-
  risk prompt change → behind its own toggle, fully revertible.**
- **72.11b** Grow the MCQ exemplar pool to 8–10 incl. `odd_one_out`.
- **72.11d** Factual audit of suspect `gold_standard.json` entries vs sources. **Verify before removing any
  exemplar as "wrong"** (a prior premise was false — Open Q #6).
- *Gate:* prompt-content assertions + schema/exemplar-count tests. **Plumbing only** (says nothing about
  whether the new angle actually lands as fun).

### Phase 3 — HTTP-routing fixes under respx mocks (no real network)
- **72.1** (RC-1) OpenTDB → emit a bare declarative fact; rewrite via `factory.chat_openai('gpt-4o-mini')`;
  deterministic entity+category fallback; **guard asserting output never contains the original question
  substring.**
- **72.3** (RC-3) Widen Tavily: 5 surprise-angle templates + `include_domains` (Mental Floss, Atlas Obscura,
  Smithsonian, Britannica); drop the 1-query/topic throttle. Slovak query angles.
- **72.4** (RC-4) Wikipedia topic path → REST summary opening paragraphs (not search snippets). **Do NOT
  re-enable topic-agnostic DYK on themed orders** (reverts #42 task 42.28).
- *Gate:* respx `assert_all_mocked=True`. **CODE-CORRECT** (request shape, parsing, guards); content quality
  is **effect, deferred to Phase 7.**

### Phase 4 — Surprise scorer + corpus shadow-correlation (local reads only)
- **72.2** (RC-2) Free heuristic surprise scorer (numbers/superlatives/contradiction/origin words high; bare
  definitions low) — *no* per-fact LLM call. Then actually call `top_by_surprise()` (defined, zero call
  sites today) and quality-weight the per-source budget (`fact_sourcer.py:47`).
- **Shadow-score the 580 corpus** and correlate the heuristic vs the existing `surprise_delight` field.
  **Label honestly:** this is *agreement with the existing LLM scorer on TEXT questions*, **not** agreement
  with human fun. Pre-commit a minimum Spearman rho (Open Q #5).
- *Gate:* positive rho on text. **Directional scorer sanity only** — says nothing about MCQ (corpus has none).

### Phase 5 — Gate plumbing as SHADOW + labelled set (deterministic mocks)
- **72.5** (RC-10/11) Wire an Answerability/surprise veto into the live scorer: port `question_critique_v2`
  Dimension 7 **with its calibration anchors**; per-dimension vetoes. (Approach A vs B = Open Q #3.)
- **72.6** **`VETO_SHADOW` first:** log what *would* be dropped, never drop. Build a boring-vs-fun labelled
  set from `triage_merged.json` (T3 quality-reject=95 vs T6 clean=191) — **TEXT only; note the MCQ gap.**
  Confirm it would kill the starboard-class on text and measure the approve-rate hit. Do **not** hardcode a
  threshold (multi-model scorer ≠ critique_v2 scale). Defer raising `MIN_OVERALL_SCORE` until supply is fixed.
- **72.7** (helps later, not "today") Re-scoring pass over already-approved questions to flag boring served
  stock. **Review-flag, don't auto-delete.** Dovetails with #63 Track B. *(Runs only once Phase 7 enables
  the scorer — it needs the LLM scorer live.)*
- *Gate:* veto plumbing unit-tested; shadow logs sane on the text labelled set. **Does NOT prove the veto
  catches boring MCQs** (none in the set).

### Phase 6 — A/B harness code, dormant (no LLM)
- **72.14** Stand up `scripts/ab_score_corpus.py` (control vs treatment) — **score-only; guard so it can
  NEVER invoke the generator.** Corpus-adapter + correlation logic unit-tested on synthetic data.
- *Gate:* harness unit-tested; dry-run on local corpus shape. **No LLM, no run.**

### Phase 7 — The ONLY spend = un-park gate (split 7a / 7b / 7c)
> The single confirming run. Budget ~$5, but **plan for 2–3×** (the escape hatch may need fix + rerun;
> keep it on its own toggle so it's revertible without re-running everything).
- **7a — read-only scoring-inference (ONLY if founder approves it as "not a generation run" — Open Q #1):**
  `MultiModelScorer` over the existing 580 corpus via `LLM_GATEWAY=openrouter` to populate answerability +
  check T3/T6 separation + two-judge agreement. ~$1–3. **Still TEXT-only.** Generates **no new questions.**
- **7b — the one generation run:** ONE small **MCQ-emphasis** batch (~20–30) through the reworked pipeline.
  Confirm: no crash; no verbatim copying; estimation/reverse patterns actually appear; `self_critique`
  telemetry + best-of-N present (72.9); distractors obey the rules; `VETO_SHADOW` would catch the dull ones
  **without** false-vetoing good ones. **This is the first real MCQ data #72 ever sees.**
- **7c — HUMAN LISTEN (the real arbiter):** founder listens to the 7b MCQs **hands-free** and judges
  "prvoplánové vs fun." **No LLM-judge proxy replaces this.**
- *Gate:* **un-park ONLY if 7b effects hold AND 7c (the founder's ear) says less boring.** Keep 7a/7b split
  so a weak scorer result never forces re-generation.

### Deferred / strategic (NOT on the ladder — explicit, not dropped)
- **72.9** (RC-7) Restore an MCQ-path gate: re-add `self_critique` as **telemetry** + enable best-of-N for
  MCQ. Lands as part of Phase 1–3 wiring but is *verified* in 7b (needs a real run). Listed here so it isn't
  lost.
- **72.15** (strategic bet, the highest-leverage root fix) Invert "fact-first" → "**angle-first, fact-
  grounded**": generate surprising angles, then bind each to a verified source fact. Large + exploratory.
  **Tackle as a follow-up once the ladder proves the periphery — OR pull forward if the founder wants the
  root fix first (Open Q #4).** Pairs with Reverse-Question-Answering (NAACL 2025). **Flagged, not dropped.**

## Do NOT retry (already tried & failed, or already shipped)

- In-prompt self-critique as the *gate* (Boring Detector / "surprise ≥ 5 preferred" / keep-if-avg-≥8) —
  self-scored, inflatable, and it *is* the status quo that produced boring output. Enforcement must be external.
- A no-copy *warning* alone for few-shot copying — already shipped; deeper shape-copying persists.
- Asking gpt-4o for ~57 questions in one call — returns 4–10; the per-pattern sub-batch architecture is the shipped fix.
- Re-pitching MCQ routing/normalization (snake_case keys, `the_`-strip, alias map, `mcq_emphasis`) — shipped (#42 A/B/D/E).
- Treating structured-output MCQ (#42 task 42.25) as *validated* — shipped + unit-tested but never run against real gpt-4o.
- Re-enabling topic-agnostic Wikipedia DYK on themed orders — reverts #42 task 42.28.

## Open questions for the founder

> **#1 is load-bearing — the whole Phase-7 gate design hinges on it.**

1. **Is a read-only scoring-inference pass over the EXISTING 580 questions (~$1–3, generates NO new
   questions) a "forbidden run" in your eyes, or does the ban cover only fresh *generation*?** (Phase 7a.)
2. **Estimation routing — 72.8 vs 72.12b:** open free-text numeric estimate (driving-safe, research-backed)
   **or** bucketed 3-option order-of-magnitude MCQ (a fun MCQ pattern)? *Recommendation:* default to open
   free-text; add `reverse_engineer` as the new fun MCQ pattern; allow bucketed-estimation-MCQ only under an
   explicit mcq-bias. Your call — it must be settled before 72.8's locking test.
3. **72.5 scorer approach:** swap `MultiModelScorer` to `critique_v2` (one prompt change, alters the 6-dim
   contract) **or** add a 2nd `critique_v2` judge (doubles scoring cost)?
4. **72.15 (angle-first root fix):** pull forward as the first real lever, or keep as a later bet after the
   periphery ladder?
5. **Minimum Spearman rho** for the 72.2 surprise scorer to count as "directionally OK" on text (e.g. ≥0.3)?
6. Does `gold_standard.json` still contain factually-wrong entries? (Human-review before reuse — 72.11d.)
7. Filing OK as #72 cross-linked to #42 (Track F-R) and #63 (un-park) — confirmed standalone, your call.

## Acceptance

- **Phases 0–6 are green offline with ZERO paid generation**, and each gate is labelled *plumbing-correct,
  not fun-validated* (no offline pass is allowed to claim "fun" or "MCQ thresholds calibrated").
- **72.13 (RC-9) lands before/with 72.8** — a test proves a non-substring-matching estimation answer is
  **not** dropped by the verifier (else the new patterns die silently at the gate).
- The **72.8-vs-72.12b routing conflict** is resolved as one documented decision **before** its locking test.
- A boring recall question like the starboard example is **flagged** by the wired veto in `VETO_SHADOW` on
  the (text) labelled set — i.e. fun is enforced in ≥1 place in *plumbing*.
- The final run (7b) produces MCQs that (a) don't crash, (b) include ≥1 working non-recall pattern, and
  (c) the founder judges **less boring by ear (7c)**. **Un-park requires 7c** — no proxy substitutes for it.
- No corpus writes occur until the founder un-parks; every change ships dormant/behind a toggle otherwise.

## Links

- Evidence + research + ranked solutions: `docs/artifacts/question-quality-fun-review-2026-06-22.html`
- Feeds the un-park decision in [[issue-63-question-quality-review]]; MCQ structural survival is
  [[issue-42-question-quality-and-mcq]] Track F-R; general growth [[issue-30-batch-generate-categories]] (also parked).
- Prior engagement work: `docs/archive/data-tasks/ENGAGEMENT_PATH_FOLLOWUP.md`.
- Method: workflow `wf_69974eb3-492` (19 agents) for the diagnosis + `wf_850581e1-f56` (7 agents) for the
  offline-validatability audit + adversarial challenge of the resequencing; top-level first-hand spot-checks
  of the load-bearing claims (corpus = zero MCQ via #63 Track B; RC-9 substring; `top_by_surprise` zero call
  sites; OpenRouter key present, `LLM_GATEWAY` unset).
- Resequencing handoff: `docs/handoffs/handoff-2026-06-22-1554.md` (offline-first, founder mandate 2026-06-22).

<!-- obsidian-links:start -->
## Súvisiace issues
[[issue-42-question-quality-and-mcq|#42 Question quality sweep + multichoice activation]] · [[issue-63-question-quality-review|#63 Question-quality review: generation audit + corpus verification]] · [[issue-30-batch-generate-categories|#30 Batch-generate questions for new categories]]
<!-- obsidian-links:end -->
