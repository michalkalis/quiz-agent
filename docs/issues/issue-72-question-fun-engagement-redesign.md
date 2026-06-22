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

- **Generation stays PARKED** (founder, 2026-06-12) — nothing here writes to the corpus until un-park.
  Most of it can be **built + shadow-tested** now; only the corpus re-score (Phase 2b) helps today.
- **Fix supply BEFORE raising the gate.** Raising the floor on a starved sourcing layer drops yield to
  ~zero. Sequence: supply → floor → conversion → premium sources.
- **Nothing here has run against real gpt-4o** (cost + park + the known MCQ crash). Magnitudes are
  hypotheses until Phase 0 + the A/B harness confirm them.
- **Sources:** keep Tavily (PAYG ok); **reject** SearXNG self-host, Brave, Firecrawl, Reddit API
  ($12k/yr), Wikidata SPARQL (produces more "which is bigger" recall). (memory: web_search_provider.)
- **No `'haiku'` model id exists in the repo** — use `factory.chat_openai('gpt-4o-mini')` for any rewrite
  step (adversarial pass caught a proposed `chat_openai('haiku')` that would crash).

## Plan (phased)

### Phase 0 — Validate the acute fix (do first; ~5 min; conserve the $10 Tavily cap)
- **72.0a** Fix the MCQ crash first so `--mcq-bias` is runnable: `return_exceptions=True` +
  per-sub-batch try/except at `advanced_generator.py:396`; make `_generate_mcq_batch_structured`
  (`:651-669`) tolerant of non-conforming items. (= #42 task 42.31 — do here or there, link it.)
- **72.0b** One clean dry-run with Tavily up (`--target-count 5`, no `--mcq-bias`, `--dry-run`). Confirm
  the sourcing log shows `web_search: N facts (N>0)` and judge the questions. **Quantifies the
  acute-vs-structural split** before any further code change.

### Phase 1 — Supply: fix the ceiling (sourcing) — highest leverage, S–M
- **72.1** (RC-1) OpenTDB → emit a bare declarative fact; rewrite via `factory.chat_openai('gpt-4o-mini')`;
  keep a deterministic entity+category fallback; **add a guard asserting the output never contains the
  original question substring.**
- **72.2** (RC-2) Free heuristic surprise scorer (numbers/superlatives/contradiction/origin words score
  high; bare definitions low) — *no* per-fact LLM call. Then actually call `top_by_surprise()` and
  quality-weight the per-source budget (`fact_sourcer.py:47`).
- **72.3** (RC-3) Widen Tavily: 5 surprise-angle templates (misconception/"actually", record, scale,
  origin-story, counterintuitive) + `include_domains` (Mental Floss, Atlas Obscura, Smithsonian,
  Britannica); drop the 1-query/topic throttle. Generate query angles in Slovak.
- **72.4** (RC-4) Wikipedia topic path → REST summary opening paragraphs (not search snippets). **Do NOT
  re-enable topic-agnostic DYK on themed orders** (that reverts #42 task 42.28).

### Phase 2 — Floor: enforce fun (the missing lever) — M
- **72.5** (RC-10/11) Wire an Answerability/surprise veto into the live scorer: port `question_critique_v2`
  Dimension 7 **including its calibration anchors** into the scorer prompt; add per-dimension vetoes
  (drop if Answerability < 4 OR surprise < 4).
- **72.6** **Shadow-mode first:** log what *would* be dropped for one batch; confirm it kills the starboard
  class and measure the real approve-rate hit; *then* flip the veto on. Calibrate the threshold
  empirically on a labelled boring-vs-fun set (the multi-model scorer uses a different scale than
  critique_v2 — do not hardcode 5.5). Defer raising `MIN_OVERALL_SCORE` until supply (Phase 1) is fixed.
- **72.7** (independent — helps TODAY) Run the veto as a **re-scoring pass over already-approved questions**
  to flag boring stock currently being served. **Review-flag, don't auto-delete** — human confirms before
  anything leaves the live store. (Dovetails with #63 Track B.)

### Phase 3 — Conversion: patterns & prompt — M
- **72.8** (RC-6) Add `estimation_challenge` + `reverse_engineer` to `PATTERNS_TO_MCQ` with their own
  recipes. **Keep `lateral` as free-text** (its answer shape fights MCQ). Broaden "comparison bet" via its
  recipe string (`:815`, add price/speed/toxicity), **not** a key rename.
- **72.9** (RC-7) Restore a gate to the MCQ path: re-add `self_critique` fields as **telemetry** and enable
  best-of-N for MCQ — but rely on the Phase-2 external gate for enforcement.
- **72.10** (RC-5) Prompt escape hatch: allow a surprising *angle* from general knowledge as long as the
  factual *claim* traces to source. Add an "Assumption-Flip" pattern + a misconception-distractor rule
  (and if it's an MCQ pattern, register it in `PATTERNS_TO_MCQ`).
- **72.11** (RC-8) Thread `question_type` into `load_gold_standard` so MCQ batches see ≥2 MCQ examples; grow
  the MCQ exemplar pool to 8–10 incl. `odd_one_out`; keep exemplars **answer-stripped/structural** to defeat
  verbatim copying. **Verify before removing any exemplar as "wrong"** (a prior premise was false).
- **72.12** Voice/driving constraints: cap MCQ at 2–3 spoken options, options at end of stem, ~15-word
  stems, prefer open numeric estimation for quantities.

### Phase 4 — Premium sources & strategic bets (later, L)
- **72.13** (RC-9, narrow) FactVerifier Tavily-down safety: when search/judge is unavailable, **tag
  `unverified` and hold for review** rather than dropping at confidence 0. Keep verification **strict** for
  factual answers (a driver can't fact-check hands-free). Do **not** re-architect — mode routing already
  shipped in #46.
- **72.14** (enabler) Stand up the never-run **A/B harness** (control vs treatment; resolvable via the
  OpenRouter gateway now that the Anthropic-key gap can route through it) to *prove* each change reduces
  boringness instead of shipping on faith.
- **72.15** (strategic bet) Invert "fact-first" → "**angle-first, fact-grounded**": generate candidate
  surprising angles (estimation/assumption-flip/reverse) then bind each to a verified source fact. The
  existing `question_generation_open.md` path already proves this works — generalize it to MCQ + text.
  Pairs with Reverse-Question-Answering (NAACL 2025).

## Do NOT retry (already tried & failed, or already shipped)

- In-prompt self-critique as the *gate* (Boring Detector / "surprise ≥ 5 preferred" / keep-if-avg-≥8) —
  self-scored, inflatable, and it *is* the status quo that produced boring output. Enforcement must be external.
- A no-copy *warning* alone for few-shot copying — already shipped; deeper shape-copying persists.
- Asking gpt-4o for ~57 questions in one call — returns 4–10; the per-pattern sub-batch architecture is the shipped fix.
- Re-pitching MCQ routing/normalization (snake_case keys, `the_`-strip, alias map, `mcq_emphasis`) — shipped (#42 A/B/D/E).
- Treating structured-output MCQ (#42 task 42.25) as *validated* — shipped + unit-tested but never run against real gpt-4o.
- Re-enabling topic-agnostic Wikipedia DYK on themed orders — reverts #42 task 42.28.

## Open questions for the founder

1. Has the Tavily-topped-up re-run been run, and what fraction of boringness does it actually recover? (Phase 0.)
2. Is `ANTHROPIC_API_KEY` / `OPENROUTER_API_KEY` now configured? (Needed for the second scorer + a clean A/B test.)
3. What approve-rate can the pipeline tolerate? (Sets sequencing — raising the floor on starved sourcing → ~zero yield.)
4. Does `gold_standard.json` still contain factually-wrong entries teaching bad facts? (Human-review before reuse.)
5. Filing OK as #72 cross-linked to #42 (Track F-R) and #63 (un-park) — or fold into one of those?

## Acceptance

- Phase 0 produces a measured acute-vs-structural split (a number, not "~90%").
- A boring recall question like the starboard example is **rejected** by the wired external gate
  (demonstrated in shadow mode on a labelled set) — i.e. fun is enforced in ≥1 place.
- MCQ generation can emit at least one non-recall pattern (estimation or reverse) end-to-end.
- The corpus re-score yields a bounded human worklist of flagged-boring served questions (review-flag, not delete).
- No corpus writes occur until the founder un-parks; every change ships dormant/behind the park otherwise.

## Links

- Evidence + research + ranked solutions: `docs/artifacts/question-quality-fun-review-2026-06-22.html`
- Feeds the un-park decision in [[issue-63-question-quality-review]]; MCQ structural survival is
  [[issue-42-question-quality-and-mcq]] Track F-R; general growth [[issue-30-batch-generate-categories]] (also parked).
- Prior engagement work: `docs/archive/data-tasks/ENGAGEMENT_PATH_FOLLOWUP.md`.
- Method: workflow `wf_69974eb3-492` (19 agents) + top-level first-hand spot-checks of the 5 load-bearing claims.

<!-- obsidian-links:start -->
## Súvisiace issues
[[issue-42-question-quality-and-mcq|#42 Question quality sweep + multichoice activation]] · [[issue-63-question-quality-review|#63 Question-quality review: generation audit + corpus verification]] · [[issue-30-batch-generate-categories|#30 Batch-generate questions for new categories]]
<!-- obsidian-links:end -->
