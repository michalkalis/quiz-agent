# Issue #135 — Gen pipeline founder feedback round 2 (prompt genericization + call-count diet)

**Triage:** ready-for-agent (D6/D7 confirmed by the founder in chat 2026-08-03)

Founder reviewed the deep-review report (`docs/research/gen-pipeline-deep-review-2026-08-03.md`) on 2026-08-03 and gave line-by-line feedback. This issue captures the locked decisions and the implementation plan. Companion artifact: `docs/artifacts/few-shot-examples-2026-08-03.html` (full gold + anti-pattern pool shown to the founder).

## Locked decisions (founder, 2026-08-03)

| # | Decision |
|---|----------|
| D1 | **Generation model is NOT fixed.** `GEN` must be easily configurable per run; prompt must be model-agnostic (no Claude-specific framing). Default model gets decided by the approved 5-model blind test (Opus/Fable/Gemini/GLM-5.1/Kimi K3) — `feedback_no_model_swaps_without_approval` still applies. Chinese models (GLM, Kimi, DeepSeek) are welcome candidates: strong results at low cost. |
| D2 | **Persona rewrite.** Drop "voice-only quiz played hands-free while driving", "heard ONCE", "non-native-English adult" — irrelevant for generation and partly untrue. Write a better generic quiz-master persona. (Clarity/speakability stays as craft guidance — founder still complains about hard-to-parse questions in O3 — but without the driving story.) |
| D3 | **Contract loosened: rules become guidance.** Rule 4 ("answer must be something the player knows") — no longer required. Rule 5 (path-to-answer besides memory) — too strict, demote to hint. Batch-shape quotas (≤30% "Which", ≥4 patterns, ≥4 openers) — demote to "vary structure" guidance. **Rule 6 (no giveaways/leakage) stays HARD.** Grounding (rule 1) stays hard *in fact-first mode* (see D8). General worry: too many guardrails over-constrain the model. |
| D4 | **Pattern library stays as inspiration only** — no mandated usage quotas (ties to D3). |
| D5 | **Question-type mix: ~80% text / 20% MCQ** as the default batch/pack composition (was more MCQ-heavy). |
| D6 | **Selector diet — CONFIRMED.** Overgeneration 3×→2× (36→24 candidates) + duel ring 5→3 neighbours (~60→~36 duel calls); optionally route critique/duels to a cheap-frontier judge (GLM/DeepSeek via OpenRouter). O4 (bidirectional duels) REJECTED — never increase call count. Ranking unification (drop "educational value", universality→red flag) stays approved. **Founder condition: log this as an explicit tracked setting change** — record old→new values + date + rationale here and keep both values config-switchable, so a future quality drop can be traced back to this change (see § Setting changes). |
| D7 | **Scoring gate redesign — CONFIRMED (founder picked 3 judges).** Drop "Faktická istota" as a gate dimension (redundant with the fact-verification step; the MCQ "exactly one defensible option" part moves to the MCQ distractor check). "Vhodnosť za volant" dropped as its own dimension — fold one-listen clarity into "Remeselné podanie". Target: 5 dimensions, judged by a panel of **3 judges from 3 families (GPT + Gemini + cheap Chinese frontier, e.g. GLM/DeepSeek) × 1 call each** (all dims in one structured output, reasoning-first per dim) ≈ 36 calls/12q (−79%). Validate the new judge against the founder's 36-rated calibration set before switching (correlation old vs new vs founder ratings). O2 (reasoning→score order + Gemini temp 1.0) approved — implement as a constraint of the new templates. |
| D8 | **Fact-first is challenged.** Founder: mandatory fact-grounding may cap creativity; the fact-verification step already guards production. Run an A/B: same model, one arm fact-first, one arm free-generation (verification moved EARLY in that arm). Fold into the blind-test round; founder blind-rates. Fact-sourcing improvements (O1) still agreed as an issue, but scoped after/with this experiment. |
| D9 | **Fact verification: cheaper arbiter.** Gemini 3.1 Pro is overkill for evidence arbitration — founder explicitly allows a simpler model here (carve-out from the no-mini-class policy, 2026-08-03). Position: keep after selection in fact-first mode (grounded candidates rarely fail; early check would 3× Tavily spend for little); early in the free-gen arm. |
| D10 | **O3 approved and broadened:** round-trip answerability check (a model attempts the question without seeing the answer) for ALL question types, not just text, placed as EARLY as possible (after generation+dedup, before critique) — also catches unclear phrasing/format, which the founder keeps seeing. Cheap model OK. |
| D11 | **O5 approved** (cost measurement phase after tuning) with caveats: no weak AWS models; Bedrock Claude access **still locked as of 2026-08-03** (probe: `AccessDeniedException` on anthropic.claude-opus-5/sonnet-5/opus-4-8 in us-east-1) — pipeline stays on OpenRouter until AWS grants the request. Re-check periodically. |

## Tasks

- [x] T1 — Rewrite `question_generation_v3_fact_first.md`: generic persona (D2), hard-rules→guidance split (D3: hard = grounding + no-giveaways + response format; everything else guidance), pattern library as inspiration (D4). Cache breakpoint layout kept. **Also applied to `question_generation_entertainment.md`** (shares the injected craft-guards block, which now references the new rule names — leaving it on the old numbered contract would have made those references dangle; entertainment keeps a 4th hard rule: voice-servable format). Prompt tests updated to the new contract.
- [x] T2 — `GEN`/`CRITIQUE` stay env-per-run (`GENERATION_MODEL`/`CRITIQUE_MODEL`); judges via `JUDGE_MODELS`, verify via `VERIFY_MODEL`, answerability via `ANSWERABILITY_MODEL`. Slugs added to `_REMAP_OPENROUTER` (verified live 2026-08-03): `glm-5.1`, `kimi-k3`, `deepseek-v4-pro`, `deepseek-v4-flash`.
- [x] T3 — Default composition ~80/20 text/MCQ as a soft target rendered into the MCQ prompt section (`MCQ_TARGET_FRACTION`); MCQ-emphasis orders keep their hard ≥7/10 quota.
- [x] T4 — `AnswerabilityStage` after dedup (all types, one `deepseek-v4-flash` call/q, blind attempt + deterministic comparison; open shapes drop only on the model's own gave-up/unclear signal; checker failure keeps the question). Default ON, `ANSWERABILITY_CHECK=0` disables. Verified live 2026-08-03.
- [x] T5 — Selector diet: overgen 3×→2×, duel ring 5→3 (both env-switchable, § Setting changes). Ranking unification in `question_critique_v2.md`: `educational_value` deleted, universality→`niche_reference` red flag (cap 4), `language_dependent`→red flag (cap 4). Pairwise duel prompt genericized (D2).
- [x] T6 — Gate v2 CODE DONE behind `GATE_V2`; **validation RAN 2026-08-03 → FAIL → default zostáva OFF** (presne per founder condition). Výsledky (n=27, `data/pilot-2026-07-11/gate_v2_validation.json`): v1 vs founder Spearman 0.161 / Pearson 0.371; v2 vs founder Spearman 0.026 / Pearson 0.186; v1↔v2 zhoda 0.879. Separácia founder-slabých (≤3) od dobrých (≥4.5): v1 = 1.89 b, v2 = 1.18 b — jeden panel-call na sudcu signál merateľne otupil (kontaminácia medzi dimenziami, ktorú per-dim calls riešili). Caveaty: n=27 s ceiling efektom (24/27 hodnotených 4+, len 3 slabé kotvy) → čísla sú šumové, ale pre-registrované pravidlo nepustí. ⚠ "36-rated" surový log nie je v repo; ground truth = 27 pilot ratingov. **Open option (issue § Notes fallback): medzistupeň 2 clustery (fun+craft) × 3 sudcovia = 6 calls/q (−57 %) — otestovať za ~2 $ na founder pokyn.**
- [x] T7 — Fact + logical verify arbiter → `deepseek-v4-pro` (D9 carve-out; ~93 % lacnejšie než gemini-3.1-pro), `VERIFY_MODEL` env switches back. Free-gen arm early-verify ordering belongs to T8's A/B wiring.
- [ ] T8 — Fact-first vs free-gen A/B wired into the blind-test round (D8); founder blind-rates.
- [ ] T9 — Cost phase (D11/O5): measure per-step spend, decide EVAL model — after T1–T8 settle.
- [ ] T10 — **Few-shot pool cleanup (own session — founder directive 2026-08-03).** The whole injected pool (32 rated golds + 14 FIXED pair variants) was run through the pipeline's own judging stage on 2026-08-03 — 2 judges (gpt-5.6-sol + gemini-3.1-pro-preview) × 7 dimensions, one call per dimension, plus the deterministic craft guards; full per-example scores, judge reasoning and format flags in **`docs/research/few-shot-examples-judged-2026-08-03.md`** (HTML twin in `docs/artifacts/`, throwaway). Results: 0/46 below the production gate (3.0/10 — gate is lenient by design), but **23/46 have ≥1 dimension ≤4** and 6 carry craft-guard flags. Worst: `gold-6` Olympic-elegance 3.64 (founder had 8) · `gold-3` Egypt butchers 4.93 · `gold-24` water-% 5.71 · `gold-21` chess (long_answer, 7-word answer — over the ≤6-word voice cap) · `gold-14` "spelled incorrectly" (stem_leak + pure English wordplay, conflicts with rule 12) · `gold-32` ARPANET year 5.79. Known false positive: `gold-19` Cleopatra stem_leak flag is an artifact of the comparison format (it is the top-scoring example, 8.86). Session scope: propose drop/rewrite for the weak tail, cross-check against the loosened contract (T1), then run the gap round (entertainment/sport/food/MCQ golds) to refill. **⚠ Founder caveat (2026-08-03): the examples may be OUTDATED — before any removals/rewrites land, the founder personally re-verifies the proposed set** (facts may have drifted since rating, and his calibration has moved since July). Deliver the proposal as an interactive review in chat, not a doc-only task.

## Setting changes (tracked — founder requirement 2026-08-03)

Quality-relevant knob changes made under this issue, so a future quality regression can be traced to its cause:

| Date | Setting | Old | New | Why | Revert |
|---|---|---|---|---|---|
| 2026-08-03 | overgeneration factor | 3× | 2× | call-count diet (D6, founder confirmed) | `OVERGEN_MULTIPLIER=3` |
| 2026-08-03 | duel ring neighbours | 5 | 3 | call-count diet (D6) | `DUEL_RING_NEIGHBOURS=5` |
| 2026-08-03 | fact/logical verify arbiter | gemini-3.1-pro-preview | deepseek-v4-pro | D9 carve-out ("overkill") | `VERIFY_MODEL=gemini-3.1-pro-preview` |
| 2026-08-03 | critique ranking dims | 7 (s universal_appeal + educational_value) | 5 + red flags | ranking unification (D6) | git history `question_critique_v2.md` |
| 2026-08-03 | default type mix | neriadené (pattern-driven) | ~80/20 text/MCQ soft target | D5 | `MCQ_TARGET_FRACTION` v `advanced_generator.py` |
| 2026-08-03 | answerability round-trip | žiadny | ON, deepseek-v4-flash, po dedupe | D10/O3 | `ANSWERABILITY_CHECK=0` |
| 2026-08-03 | generation contract | 15 hard rules + kvóty | 3 hard rules + craft guidance | D2/D3/D4 | git history prompt šablón |
| (pending) | gate shape | 7 dim × 2 judges × 1 call/dim (14/q) | 5 dim × 3 judges × 1 call (3/q) | D7; čaká na kalibračnú validáciu | `GATE_V2` (default off) |

## Status 2026-08-03 (agent run)

- T1–T7 shipped a nasadené (quiz-pack-api v29). T6 validácia RAN → FAIL → `GATE_V2` zostáva OFF (detail v T6 vyššie).
- OpenRouter kredity: vyčerpané počas behu (~$0.43), founder dobil na $40 → validácia dobehla; zostatok ~$9 (validácia stála ~$1.4).
- Gate v2 panel call overený živo na deepseek-v4-pro; answerability checker overený živo na deepseek-v4-flash.
- Otvorené: T8 (fact-first A/B v blind teste), T9 (cost fáza), T10 (few-shot cleanup, interaktívne), + prípadný 2-cluster gate experiment (T6 fallback).

## Future (out of scope here, founder wish 2026-08-03)

**Self-improving pipeline (learning loop):** when a question is rated well (by the founder or by users in the app), a review process should reverse-engineer *why* it works and feed that back into the pipeline (gold pool, critique anchors, pattern weights). Same for badly-rated questions. Tracked as its own TODO line; needs a design round (data source = in-app ratings + founder ratings; output = automated gold/anti-pattern candidates + anchor updates).

## Notes

- Selector-quality research caveat (report §4): duels beat absolute scores and selector quality caps best-of-N gains — that's why T5 reduces breadth (2× overgen, ring-3) rather than deleting duels outright. If costs must fall further, the next lever is cheaper judge models, not fewer comparisons.
- Gate single-call risk: per-dimension calls were introduced because batched grading contaminated scores. Mitigations in T6: reasoning-first per dimension inside structured output + fewer dims + calibration-set validation before switch. If correlation drops materially, fall back to 2 calls/judge (fun-cluster + craft-cluster).
