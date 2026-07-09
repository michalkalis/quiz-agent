# #72 follow-up — Reviewer + craft-guard upgrade (new-session execution plan)

**Parent:** `docs/issues/issue-72-question-fun-engagement-redesign.md` (this is a focused sub-plan, not a new issue)
**Calibration ground-truth:** `docs/research/question-quality-founder-calibration-2026-07-09.md` (36 founder ratings, 2026-07-09)
**Raw ratings log:** this session's `scratchpad/ratings_log.md` — copy into the research doc's appendix if wanted before it's GC'd.
**Created:** 2026-07-09 · **For:** fresh Opus session · **Owner:** Michal

---

## TL;DR for the next session

The founder rated 36 corpus questions and defined *what makes a question fun*. Cross-referenced with the code, **the wanted behaviour is 70% already built in #72 but dormant, and 30% genuinely missing**. This plan (a) runs the research the founder asked for, (b) activates/tunes the dormant levers, (c) adds the missing craft guards, (d) rewrites the reviewer rubric to match founder calibration, (e) validates against a fresh + the degraded June batch. **Use `Workflow` for the research fan-out (founder asked for workflows).** Founder is the subjective judge — check in at the gates.

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

## Open product decisions for the founder (surface live next session)

- **Category taxonomy**: which categories belong in the *general-knowledge* pool vs. dedicated packs (Marvel/HP/sports niche)? Affects routing + audience fit.
- **MCQ vs open default mix**: how aggressively to shift toward MCQ overall (founder leaned MCQ 3× but open free-text still wanted for short gradable answers).
- **Cliché policy**: reject outright, or allow with a freshness reframe?

---

## Pointers / gotchas
- Prod reads via `fly proxy 15432:5432 -a quiz-pack-db` + `postgres` superuser (`OPERATOR_PASSWORD` from `fly ssh console -a quiz-pack-db`). Stop the proxy after.
- Prod corpus = 565 approved in Postgres `questions`; newest = **May 19 (pre-regression)**. Degraded output lives in `data/audit-2026-06-18/`, not prod.
- #72 dormant flags: `GENERATION_MODEL`, `V3_ESCAPE_HATCH`, `VETO_SHADOW`, `MCQ_CRITIQUE_TELEMETRY`. Ralph loops disabled (founder 2026-07-05) — this runs as a founder-driven session, not overnight.
- Everything stays behind flags / no corpus writes until Phase 4 sign-off (#72 reversibility contract).
