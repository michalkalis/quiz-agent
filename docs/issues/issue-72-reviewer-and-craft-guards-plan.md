# #72 follow-up — Reviewer + craft-guard upgrade (new-session execution plan)

**Parent:** `docs/issues/issue-72-question-fun-engagement-redesign.md` (this is a focused sub-plan, not a new issue)
**Calibration ground-truth:** `docs/research/question-quality-founder-calibration-2026-07-09.md` (36 founder ratings, 2026-07-09)
**Raw ratings log:** this session's `scratchpad/ratings_log.md` — copy into the research doc's appendix if wanted before it's GC'd.
**Created:** 2026-07-09 · **For:** fresh Opus session · **Owner:** Michal

---

## TL;DR for the next session

The founder rated 36 corpus questions and defined *what makes a question fun*. Cross-referenced with the code, **the wanted behaviour is 70% already built in #72 but dormant, and 30% genuinely missing**. This plan (a) runs the research the founder asked for, (b) activates/tunes the dormant levers, (c) adds the missing craft guards, (d) rewrites the reviewer rubric to match founder calibration, (e) validates against a fresh + the degraded June batch. **Use `Workflow` for the research fan-out (founder asked for workflows).** Founder is the subjective judge — check in at the gates.

**Status 2026-07-10:** Phase 1 research **DONE** → `docs/research/question-craft-prior-art-2026-07-10.md` (5 cited briefs + synthesis, 25-row finding→change mapping). Phase 4.1 degraded-set rating **DONE via 5-question triage sample** (founder's call) → calibration doc addendum; verdict: batch avg ≈3.8, not trash — its dominant defect is **near-duplicate flooding** (bridge 3×, stomach-acid 4× in 27 Qs), i.e. the known dedup no-op, so no further rating needed. **Phase 2 code DONE** (`a4e67f4`): `app/scoring/craft_guards.py` (stem-leak + T/F-balance, shadow default, `CRAFT_GUARDS_ENFORCE` to drop), `VETO_ENFORCE` promotion, in-batch dedup (Jaccard 0.60) in `DedupStage`, founder anchors + 5 craft red flags in `SCORING_PROMPT` / `question_critique_v2.md` / score-questions skill; suite 569 green ×2. Next: Phase 3 (needs the 3 open product decisions below).

**Status 2026-07-10 (evening session — Phases 2-validation, 3, 4 executed):**
- **Phase 2 validation DONE** (`009eeb9`) — no prod pull needed: 35/36 rated questions matched in the local `data/issue63/chroma_export_580.json` (only Q1 Copernicus absent, a 4/5, non-critical). First run exposed real mis-calibration (2 of 3 low anchors approved; 5 leak-guard false positives). After recalibration: **all 3 low anchors caught** (Rome 1/5 + King-of-Pop 2/5 → `answerability_surprise_veto`; cocoa 2/5 → new `long_answer` guard), **zero flags on founder 4+/5 keepers** (umbrella, Hogwarts, NZ, mile, Point Nemo), Napoleon leak still caught, Spearman ρ≈0.59 (n=31). Guard fixes: gloss-stripped core answer, choice-in-stem exemption, half-coverage head-token rule, annotated-T/F detection, new `long_answer_reason` (>6 words, comma/gloss excluded) wired into ScoringStage. SCORING_PROMPT gained 4 framing caps (clue-pile, landmark giveaway, vague what-is-special, bare recall) — these make the veto fire. **Known corpus-artifact FP:** verbosely-stored great answers (Wilhelm 9w) trip `long_answer`; irrelevant for new generation where the prompt mandates the canonical short form. **Veto in enforce would also drop founder-3/5s (Inception, Rio)** — acceptable per "fun primary" but the founder should know. **Verdict: reviewer calibrated; VETO_ENFORCE + CRAFT_GUARDS_ENFORCE are safe to flip for fresh generation runs** (corpus re-scoring would need the long-answer caveat).
- **Phase 3 DONE** (`549cfc2`) — craft guards mirrored into the live v3 generation prompt behind new dormant `GEN_CRAFT_GUARDS` flag (same byte-identical-off mechanism as the escape hatch): no stem leak (Napoleon example), one sharp hook, name-the-wrong-assumption reasoning step (research finding #1), gettable answer + retro-obvious test, T/F ~50/50 + telegraphed-T/F→MCQ transform (St Andrews example), no unguessable open numeric (heart-beats carve-out), mandatory 1–2-sentence `explanation` context payoff. **Format-suitability step (locked decision) is a composition, not a new LLM hop:** `PATTERNS_TO_MCQ` routing (true_false/year_guess/order_of_magnitude verified firing) + prompt rule 6 for text batches + reviewer veto backstop + `--mcq-bias` order hook for the ~50/50 start. **Context payoff needs no schema change** — `explanation` already flows prompt→model→DB; app/serving playback logged as follow-up in TODO. OpenRouter slug `anthropic/claude-opus-4.8` **verified against the live catalog**.
- **Phase 4 (fresh batch) GENERATED:** harness drift found+fixed (`3d07be5` — `run_validation_flow` lacked `mcq_bias`, every topic died with AttributeError). **31 questions** (4 topics × 8, 2 topics MCQ-emphasised) via the persist-free harness with `GENERATION_MODEL=claude-opus-4-8` + `V3_ESCAPE_HATCH` + `GEN_CRAFT_GUARDS` + `VETO_SHADOW`, `LLM_GATEWAY=openrouter`. **Objective metrics (Phase 4.3): 0 stem-leaks · 0 long answers · T/F keys 2/2 FALSE (old corpus: 94% True) · MCQ share 61% · open answers all ≤6 words · 0 veto/craft shadow flags · 6% "Which" openers.** Two proxy soft-fails, both non-blocking: one MCQ *option value* runs 8 words ("Two and a half times around the Earth" — the option-brevity rule isn't in the prompt, only answer brevity), and the `text` type drew no library reasoning-pattern label in this batch (patterns 1–6 labels; MCQ side had 4 distinct reasoning patterns). Output: `apps/quiz-pack-api/data/validation-2026-07-10/` (gitignored data dir — `fresh_batch.json`, `metrics.json`, `fresh_batch_review.md`). **→ founder rating of the fresh batch (Phase 4.2) is the remaining human gate; then decide the enforce-flag flip + un-park (both founder calls).**

**Status 2026-07-10 (Phase 4.2 human gate — PASSED, plan COMPLETE):**
- Founder rated the fresh batch (`fresh_batch_review.md`): 10 questions rated — #1 burnt steak, #4 Venus/Mercury, #6 ISS free-fall, #7 neutron-star teaspoon, #9 ginger cats, #10 newborn red, #12, #17, #20, #28 — **all 5/5** ("generovane otazky su mega dobre, fakt som nadseny"). Target was median ≥4, zero craft-defect outliers → **exceeded**.
- Founder decisions: (a) **flip the enforce flags** — new-pipeline config is now the standard for generation runs (`GENERATION_MODEL=claude-opus-4-8`, `V3_ESCAPE_HATCH`, `GEN_CRAFT_GUARDS`, `VETO_ENFORCE`, `CRAFT_GUARDS_ENFORCE`); (b) **#72 un-parked and closed**; (c) **old prod corpus to be archived** (not deleted) and replaced by new-pipeline output; (d) generate **+100 questions** the same way immediately.

**New findings folded in (2026-07-10 sample):**
- **Deducible-numeric nuance (Phase 2 check 3):** the unguessable-open-answer guard must NOT catch numerics the player can actively estimate (heart-beats/day rated 5/5 — "you can count the beats"). Estimable-by-reasoning → keep open + accepted-range grading; undeducible (spider-silk class) → reject or MCQ.
- **NEW scope — post-answer context payoff (Phase 3, new item 5):** founder asked that answers carry 1–2 sentences of spoken context ("how long the bridge is, where it's located… what is interesting about the river"). Generation-side: new prompt output + model field (check `headline_answer` semantics before adding a field). Serving/iOS playback is its own follow-up task — out of this plan's scope, log it in TODO when Phase 3 lands.
- **Dedup guard belongs in scope:** the June batch shows dedup no-op producing 3–4 copies per fact within ONE batch of 27. Phase 2/3 must include at least an in-batch near-duplicate check (cross-corpus dedup stays #42's port task).

**Locked founder decisions (do not re-litigate):**
- Fun/creativity is **primary**, but **answers must stay ≤ a few words** and gradable.
- **True/false and numeric-"estimate" questions → MCQ** (options or accepted range).
- Feedback and prompts are in **English** (generation is English).
- Interrogative openers (which/who/what) are **not banned** — just scrutinised.

---

## Gap analysis — founder principle → current code → action

| Founder finding | Current code state (verified) | Action |
|---|---|---|
| **T/F always guessable** (32/34 = 94% "True") | **No guard anywhere** in gen or scoring | **NEW**: T/F balance rule in gen prompt + reviewer flag; prefer T/F→MCQ conversion (widen `PATTERNS_TO_MCQ`) |
| **Answer-leak in stem** (Jaws, Napoleon) | Only soft "Predictable answers from question wording" heuristic (`v3` Boring Detector, `critique` −2). No dedicated stem-leak check in the ship gate | **NEW/PROMOTE**: explicit stem-leak check in reviewer; strengthen gen instruction with examples |
| **Unguessable open numeric answer** (spider-silk, Moon, LEGO) | `critique_v2` has Dead-End / Answerability anchors, but the `scoring.py` `answerability_surprise_veto` is **shadow-only** (`VETO_SHADOW` off, never drops) | **ACTIVATE + tune**: turn veto from shadow→enforcing (calibrated), OR route numeric patterns to MCQ (`year_guess`/`order_of_magnitude` already in `PATTERNS_TO_MCQ` — verify they fire) |
| **Padded multi-clue stems** ("list of properties") | `v3` Brevity Guidance targets *answer* length hard; question-length only soft ("1–2 sentences") | **STRENGTHEN**: "one sharp hook, not a clue-pile" rule + reviewer penalty |
| **Overexposed cliché** (King of Pop, Monopoly) | **No check anywhere** | **NEW**: cliché/over-exposure flag in reviewer (LLM judgment + optional known-cliché list) |
| **Boring first-degree recall** | `v3` Boring Detector bans "capital of…/who wrote…"; **but** live path is `v3_fact_first`+GPT-4o and quality regressed 2026-05-20 | **ACTIVATE #72 Lever A/B**: `GENERATION_MODEL`→`claude-opus-4-8`, v3 escape hatch on |
| **Ambiguous/multi-part answer** hard to grade | `answer_brevity` deterministic dim exists; Driving-Friendliness dim penalises lists | **KEEP**; add explicit "single unambiguous answer" reviewer check |
| Fun-fact framing, surprise, hidden-layer, active-thinking (the 5/5 drivers) | `surprise_delight`, `clever_framing`, `conversation_spark` dims already score these | **KEEP + re-weight** per calibration; add anchors from the rubric's 5/5 examples |

**Regression to confirm:** founder ratings peaked at the **Mar 19 `v2_cot`** wave (4.50) and drifted to 4.20 by May; #72 dates the degradation to **2026-05-20** (sourcing made mandatory → `v3_fact_first` always, GPT-4o). Verify the June-18 audit set (`data/audit-2026-06-18/`) is the flat, degraded output and rate it (below).

---

## Phase 1 — Research (Workflow fan-out; founder asked for prior-art-backed proposals)

Run a `Workflow` with parallel research agents, each producing a cited brief. Founder quality bar: outward-sourced + cited, prior-art first, proven **and** novel techniques. Analogy the founder named: **joke-writing craft**.

Research questions (one agent each, then a synthesis agent):
1. **Comedy/joke-writing craft** — setup→misdirection→punchline, the "surprise/incongruity" theory of humour, the "reveal" mechanics; what transfers to trivia framing. (Cited.)
2. **Trivia/pub-quiz design best practice** — what makes a question "tellable" and fair; the difference between recognition, recall, and deducible answers; how good setters avoid givens and clichés. (Sources: quiz-league guides, LearnedLeague, sporcle/AGT design notes, academic if any.)
3. **LLM creativity elicitation** — current techniques to push an LLM off the boring mean: temperature/sampling, persona/role prompting, "generate then critique then rewrite", diversity/novelty constraints, best-of-N with a novelty judge. Prior art + what's new (2025–2026). Tie to our existing critique→rewrite loop.
4. **Answer-design & auto-grading** — designing questions whose answer is short, unambiguous, and machine-checkable for a voice grader; when to force MCQ; how to build fair distractors and accepted-answer sets.
5. **Anti-patterns / de-biasing** — true/false answer-balance, answer-leak detection, over-exposure/cliché detection; concrete detection heuristics.

Synthesis agent → a single cited brief mapping each finding to a concrete pipeline/reviewer change, cross-checked against the calibration rubric. Save to `docs/research/question-craft-prior-art-2026-07-xx.md`.

---

## Phase 2 — Reviewer / scoring rewrite (the founder's explicit ask)

Files: `apps/quiz-pack-api/app/orchestrator/stages/scoring.py`, `app/scoring/multi_model_scorer.py`, `prompts/question_critique_v2.md`, `.claude/skills/score-questions/SKILL.md`.

1. **Add the missing hard checks** to the reviewer (each drops or flags):
   - *Stem answer-leak* — answer word/synonym present or trivially derivable from the stem.
   - *T/F balance* — if `true_false`, enforce corpus-level ~50/50; flag lone-true telegraphing; prefer conversion to MCQ.
   - *Unguessable open answer* — numeric/target answer not deducible from stem AND not MCQ → reject or force MCQ.
   - *Cliché/over-exposure* — LLM judgment "has this been on a thousand quizzes?"; optional curated cliché list.
   - *Single unambiguous answer* — accepted answer is short, one clause, gradable.
2. **Promote the dormant `answerability_surprise_veto`** from shadow to enforcing, **recalibrated** against the rubric (the founder's 2/5s and 1/5 are the negative anchors; the 5/5s the positive).
3. **Re-anchor the LLM dimensions** (`surprise_delight`, `clever_framing`, `conversation_spark`, `driving_friendliness`) with concrete examples from the calibration doc so scores track the founder's scale. Re-check thresholds (`MIN_OVERALL_SCORE`, skill's approve≥8/revise/reject).
4. Keep the deterministic `answer_brevity` + `distractor_quality` dims.

**Validation of the reviewer itself:** run the new reviewer over the exact 36 rated questions; its verdicts must correlate with the founder's 1–5 (esp. reproduce the low outliers: Rome 1/5, King-of-Pop 2/5, chocolate 2/5). If it approves those, it's mis-calibrated.

---

## Phase 3 — Generation prompt + routing changes

Files: `prompts/question_generation_v3_fact_first.md`, `question_generation_v2_cot.md`, `advanced_generator.py`, `pattern_routing.py`, `generation.py`, `feature_flags.py`.

1. **Activate #72 Lever A/B**: set `GENERATION_MODEL=claude-opus-4-8` (via OpenRouter #53), enable the v3 creative escape hatch (surprising angle, answer still source-traced). This is the single biggest quality lift and is config-only.
2. **Add craft guards to the prompt** (mirror the reviewer): explicit no-stem-leak rule + example, "one sharp hook not a clue-pile", T/F must be genuinely 50/50 or become MCQ, numeric-estimate must be MCQ/range.
3. **MCQ routing**: verify `year_guess`/`order_of_magnitude`/`true_false` in `PATTERNS_TO_MCQ` actually fire; use the `--mcq-bias` / `mcq_emphasis` quota hook to lift MCQ share for estimate/T-F types per founder pref. Keep open free-text for genuinely gradable short answers.
4. Apply the founder's **transform rule**: telegraphed T/F → extract the surprising number → ask it directly as MCQ (e.g. Golf "22 holes" example).

---

## Phase 4 — Validation (founder-in-the-loop)

1. **Rate the degraded set**: pull the `data/audit-2026-06-18/` open+MCQ+lateral questions (the genuinely-newest, post-regression output) and have the founder rate a sample — anchors the low end that this session's prod sample under-covered. Confirm which batch the founder meant by "the new batch."
2. **Generate a fresh small batch** with the new pipeline (Opus + guards, behind flags) and have the founder rate it the same way. Target: median ≥ 4, no craft-defect outliers, T/F ~50/50, zero stem-leaks.
3. Measure objectively: T/F true-ratio, stem-leak rate, MCQ share for numeric/estimate, answer word-count distribution.
4. Only then discuss un-parking #72 / running #30 corpus generation (founder owns that trigger).

---

## Product decisions — RESOLVED by founder 2026-07-10 (locked)

- **MCQ vs open mix**: start **~50/50**; the real ask is a **per-question format-suitability judgment in the pipeline** (founder verbatim: "idealne by bolo keby to nejaky krok z pipeline sam posudi… co sa viac odhaduje je viac mcq") — estimation/guessing-shaped questions route to MCQ, short gradable factual answers stay open. Founder can't set an objective global ratio yet; revisit with data after the validation batch. → Phase 3 adds a format-suitability step/criterion, not a hard quota.
- **Cliché policy**: **reject outright** — no reframe loop; the corpus is surprising facts only.
- **Category taxonomy**: **general pool = universal topics only** (science, history, food, geography, language, entertainment…); fandom/niche (Marvel, HP, football…) never in surprise-me — dedicated packs only. → topic-pool + routing must respect this split.

---

## Pointers / gotchas
- Prod reads via `fly proxy 15432:5432 -a quiz-pack-db` + `postgres` superuser (`OPERATOR_PASSWORD` from `fly ssh console -a quiz-pack-db`). Stop the proxy after.
- Prod corpus = 565 approved in Postgres `questions`; newest = **May 19 (pre-regression)**. Degraded output lives in `data/audit-2026-06-18/`, not prod.
- #72 dormant flags: `GENERATION_MODEL`, `V3_ESCAPE_HATCH`, `VETO_SHADOW`, `MCQ_CRITIQUE_TELEMETRY`. Ralph loops disabled (founder 2026-07-05) — this runs as a founder-driven session, not overnight.
- Everything stays behind flags / no corpus writes until Phase 4 sign-off (#72 reversibility contract).
