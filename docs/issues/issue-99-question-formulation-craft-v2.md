# #99 — Question-formulation craft v2 (G3 blind-rating fixes)

**Triage:** enhancement · ready-for-agent
**Status:** Planned 2026-07-16 from the founder's G3 blind-rating (2026-07-15, [`corpus-blind-sample-2026-07.md`](../testing/runs/corpus-blind-sample-2026-07.md)). Generation stays **PARKED** — this ships prompt/rubric/guard changes + tests only, no generation run, no corpus writes. Execute before any future volume gen (#30 / #95 packs).

## 1. Why — what the G3 ratings showed

Founder rated 10 blind questions (5× Opus 4.8, 5× glm-5.2). Facts/ideas scored well (surprise, hidden layer work — Q1 octopus 5/5, Q6 tank-tea idea 5/5). **No model won** (glm ~3.8 vs Opus ~3.4, inside 5+5 noise). The shared weakness of BOTH models is **question formulation** — 4 recurring craft-defect classes the current pipeline neither instructs against nor catches:

| # | Defect class | G3 evidence | Why current guards miss it |
|---|---|---|---|
| D1 | **Deductive giveaway** — stem framing lets the player *derive* the answer without knowing the fact | Q6 "what beverage" + British tank → tea (idea 5/5, format 3/5); Q9 "only two-peninsula state" → any US player knows; Q8 "Renaissance genius + inventions" → da Vinci guessable | `stem_leak_reason` (`app/scoring/craft_guards.py:87-139`) is **lexical** (token overlap). Prompt rule 1 in `_V3_CRAFT_GUARDS_SECTION` targets literal leaks (Napoleon example). Neither covers *semantic* derivability. |
| D2 | **Unanchored referent / missing context** — a term, claim, or comparison with nothing for the solver to hold onto | Q2 "hippeus" undefined → question collapses; Q7 record temperature with **no date**; Q10 "appear the same size" — from where, for whom? | No rule anywhere in `question_generation_v3_fact_first.md` or the guards section about defining terms, dating records/milestones, or stating vantage points. Interacts with the ≤5-word **answer** cap: context evicted from the answer must land in the stem, and today nothing says *how* (→ it lands as a giveaway, D1, or not at all, D2). |
| D3 | **Units / localization** — imperial-only figures unusable for a non-US/non-native audience | Q7 "100 degrees Fahrenheit" — a Slovak player can't convert; founder: °C or both | Base prompt has "no US-specific content" (line 108) but **no units rule**; no deterministic check either. |
| D4 | **Convoluted wording** — stem hard to parse, especially read aloud while driving | Q9 "never more than six miles from a body of water" — founder: hard to understand | Only the soft "1–2 sentences / 10-second read-aloud" nudge (v3 prompt lines 200-203). Critique has a `clarity` dim but the **MCQ path skips critique entirely** (`advanced_generator.py:351-364`, telemetry-only behind `MCQ_CRITIQUE_TELEMETRY`). |

Secondary G3 confirmations (no new work, keep as-is): exact-number recall → MCQ was the right call (Q4 rated as correctly formatted — routing shipped in #72 works); **audience lens = non-native English speaker** (Q3 rated "optikou non-native") — worth one explicit line in prompt + scorer.

**Not the root cause (founder-verified 2026-07-15, don't re-chase):** question-length cap (none exists — only the soft nudge), and model choice.

## 2. What already exists (build on it, don't duplicate)

- `_V3_CRAFT_GUARDS_SECTION` (`app/generation/advanced_generator.py:105-118`) — 8 gen-prompt rules behind `GEN_CRAFT_GUARDS` (standard config since the 2026-07-10 enforce-flip). **New rules go here**, same injection mechanism (`advanced_generator.py:765-766`).
- `app/scoring/craft_guards.py` — deterministic stem-leak / long-answer / T-F-balance checks, wired into `ScoringStage` (`app/orchestrator/stages/scoring.py:146-203`), drop under `CRAFT_GUARDS_ENFORCE`.
- `SCORING_PROMPT` Clever Framing caps (`app/scoring/multi_model_scorer.py:138-145`) — already caps 7 defect shapes at 3/10. **New caps go here.**
- `question_critique_v2.md` clarity/answerability dims — text best-of-N path only.
- Calibration ground truth: [`question-quality-founder-calibration-2026-07-09.md`](../research/question-quality-founder-calibration-2026-07-09.md) + the G3 file — the 10 G3 questions are the new validation anchors (Q6/Q9/Q2/Q7/Q10/Q8 negatives, Q1 positive).

## 3. Plan

### Phase 1 — Generation prompt: 4 new craft rules + answer-cap interplay

File: `_V3_CRAFT_GUARDS_SECTION` (`advanced_generator.py:105-118`); base prompt `prompts/question_generation_v3_fact_first.md` only if a rule is flag-independent (audience line).

1. **Rule 9 — no deductive giveaway.** Self-test: *"Could a player with zero knowledge of the fact derive the answer from the stem's framing alone (stereotype, elimination, famous-person pattern)?"* Negative examples verbatim from G3: British tank + "what beverage" → tea; "only state with two peninsulas" → lookup-able identity. Fix pattern: ask about the *surprising detail* instead of the identity the frame gives away (Q6 → ask what the built-in vessel is for, without naming the drink category; or flip to MCQ where the giveaway hint is removed).
2. **Rule 10 — anchor every referent.** Unfamiliar term → gloss it in the stem ("hippeus, a citizen class"); record/first/milestone → date it (year or era); perceptual claim → vantage ("in Earth's sky"). Explicit note: *context belongs in the stem as a neutral anchor, never as a category hint* — this is the sanctioned home for words evicted by the ≤5-word answer cap.
3. **Rule 11 — metric-first units.** °C, km, kg primary; imperial only in parentheses if the source figure is iconic ("100 °F (38 °C)"). Applies to stem, options, and explanation.
4. **Rule 12 — read-aloud clarity.** One idea per sentence, no nested negation, no double-condition phrasing ("never more than X from Y"); numbers as a person would say them. Keep the existing 10-second self-test, add "if a non-native listener would need a second pass, rewrite".
5. **Audience line (base prompt):** one sentence — target player is a *non-native English speaker*; obscure-to-native ≠ obscure-to-us (ampersand class), and vice versa.

### Phase 2 — Reviewer/scorer: caps + deterministic checks

Files: `multi_model_scorer.py:138-145`, `prompts/question_critique_v2.md`, `app/scoring/craft_guards.py` + `ScoringStage` wiring, tests alongside existing guard tests.

1. **Clever Framing caps** for D1 (deductive giveaway — LLM judgment, the lexical guard can't see it), D2 (unanchored referent / undated record), D4 (convoluted stem). Anchor each with its G3 example so judges calibrate.
2. **Deterministic `units_reason` guard (D3):** imperial marker (`°F`, `Fahrenheit`, `miles`, `mph`, `feet`, `pounds`, `gallons`…) in stem/options/answer without a metric equivalent nearby → flag; drop under `CRAFT_GUARDS_ENFORCE`. Cheap regex, near-zero FP risk; exempt idioms/fixed names ("Mile" in proper nouns — reuse the choice-in-stem exemption style).
3. **Deterministic `undated_record_reason` (D2 subset), shadow-only:** superlative/record marker (`first time`, `record`, `milestone`, `never before`) with no 4-digit year/decade/era token in stem+explanation → flag for telemetry. Heuristic; stays shadow (never drops) until validated.
4. **Critique v2:** fold D1/D2/D4 anchors into the existing `clarity`/`answerability` dims (text path). Do **not** build a new MCQ critique hop — the ScoringStage LLM rubric already covers MCQ questions; the critique-skip gap is closed by the scorer caps (note this explicitly in the plan-of-record so nobody re-adds an LLM hop — hot-path LLM minimalism).

### Phase 3 — Validation (offline, no founder gate yet)

1. **Regression anchors:** run the updated scorer over the 10 G3 questions (they live in `apps/quiz-pack-api/data/generation-2026-07-10/`, ids in the G3 answer key). Pass = Q6, Q9, Q2, Q10 get capped/flagged (≤3 Clever Framing or guard flag); Q1 (5/5) stays clean; Q7 trips the units guard. Zero flags on the 2026-07-10 fresh-batch 5/5 set (`data/validation-2026-07-10/`) — the false-positive fence.
2. **Objective metrics extension:** add units-violation rate + undated-record rate to the existing metrics script output.
3. Full quiz-pack-api suite green ×2 (`LLM_GATEWAY=direct` pinned, per test-gate hermeticity).

### Phase 4 — Founder gate + model decision (deferred to un-park)

At the next generation run (volume gen for #30/#95 — founder triggers):
1. Generate a small batch with the new rules; blind sample G3-style (10 q).
2. Target: median ≥4, **zero** D1–D4 defects in founder notes.
3. **Model decision rides on this batch:** G3 ended with no winner; if the craft fixes hold parity, **glm-5.2 wins on cost** ($0.007/q vs Opus ≥$0.028/q — 4× cheaper at volume). Set `GENERATION_MODEL` then, not now.

## 4. Scope guard

- Phases 1–3 = prompt text, rubric text, ~2 small deterministic checks + tests. No schema, no migration, no deploy, no generation spend (Phase 3 scorer runs are the only LLM calls; judges are gpt-4.1-mini + sonnet — cents).
- Phase 4 is founder-owned and explicitly out of the agent run.
- Don't touch: pattern routing (works), answer-brevity machinery (works), dedup, sourcing.

## 5. Done =

- [ ] 4 new rules in `_V3_CRAFT_GUARDS_SECTION` + audience line, with G3-verbatim examples
- [ ] Scorer caps (D1/D2/D4) + `units_reason` enforce-capable + `undated_record_reason` shadow
- [ ] Critique v2 anchors updated (text path)
- [ ] G3-anchor regression: 4 negatives flagged, Q1 + 2026-07-10 5/5 set clean
- [ ] Suite green ×2, lock-in test extended (2026-05-20-class strip protection covers the new rules)
- [ ] TODO + INDEX updated; Phase-4 gate recorded as the un-park step
