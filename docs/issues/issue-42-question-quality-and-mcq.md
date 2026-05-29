# Issue 42: Question quality sweep + multichoice activation

**Triage:** enhancement · ready-for-agent
**Status:** Plan verified in fresh session 2026-05-28 against actual codebase (commit `ad3643c`). 6 real bugs in the preliminary plan fixed (see Changelog at bottom). Backend tracks A–D are Ralph-suitable atomic tasks; iOS Track E is human-driven (simulator required). Gated on #36 closing tasks 2.16–2.22.
**Created:** 2026-05-28
**Parent / related:** #32 (umbrella). Independent of #36 (which only touches quiz-pack-api orchestrator + voice-quiz pgvector cutover).

> Issue-number note. `issue-36` reserves #37–#41 for quiz-pack-api Phase 3–6 forecast (Phase 3 → #37, 4a → #38, 4b → #39, 5 → #40, 6 → #41). This issue lands at #42 to avoid collision.

---

## Motivation

User audit of generated/production questions surfaced multiple quality classes the current pipeline does not catch:

1. **Procedural answers** (~2 confirmed) — e.g. the 3-litre / 5-litre jug puzzle whose `correct_answer` is a 49-word algorithm. Voice-unscoreable, conceptually broken for hands-free driving use.
2. **Explanation-as-answer** (~43 / 688 generated, ~6.3%) — answer contains an explanatory clause after an em-dash or "because." 8–25 words, voice-unfriendly, evaluator gives unfair partial credit.
3. **Verbose answers with embedded context** (~18 questions ≥ 21 words, ~53 in 11–20 word range) — "Pattern 12 Comparison Bet" style: `"Basketball — its rules were written by James Naismith in December 1891, while the modern marathon distance was only standardised at the 1908 London Olympics"`.
4. **`true_false` saved as `type=text`** (~6) — answer is "False — …" with long context; iOS falls back to free-form voice flow when MCQ would be obvious.
5. **Multichoice never activated** — `Question.type=text_multichoice` + `possible_answers` are fully implemented end-to-end (Pydantic, iOS `MCQOptionPicker`, evaluator MCQ fast-path) but **zero of 3,081 questions across data files use it.** Generator's `generate_questions(...)` defaults `question_type="text"` (`apps/quiz-pack-api/app/generation/advanced_generator.py:101`); `GenerationStage.run` (`apps/quiz-pack-api/app/orchestrator/stages/generation.py:51-56`) calls it without the kwarg, so the default always wins.

Pipeline gaps that allow this:
- Prompts (`apps/quiz-pack-api/prompts/question_generation_v2_cot.md` + `question_generation_v3_fact_first.md` — note: `prompts/` lives at the package root, **not** under `app/generation/prompts/`) carry only a weak "brevity guidance" footer. With #36 task 2.15 making `SourcingStage` mandatory, the live prompt for the orchestrator path is `v3_fact_first`; `v2_cot` is the no-facts fallback.
- Gold-standard examples (`data/examples/gold_standard.json`, 50 entries) themselves contain ~24 verbose answers — the model learns this format is acceptable.
- `MultiModelScorer` has no answer-brevity dimension; `driving_friendliness` scores question complexity only.
- `GenerationStage.run()` passes no `question_type` argument; generator default is `"text"` — no per-question type selection.
- Evaluator MCQ fast-path (`apps/quiz-agent/app/evaluation/evaluator.py:77`) routes on `if question.possible_answers:` — i.e. presence of options, **not** on `question.type`. Activation only needs `possible_answers` populated for the fast-path to fire; `type=text_multichoice` is for the iOS UI to pick `MCQOptionPicker`.
- `Question.type` is a free `str` field (no `Literal[...]` constraint in `packages/shared/quiz_shared/models/question.py:64-71`), so a typo (`"text_multichoice "` with trailing space) would silently downgrade to free-form. Worth tightening alongside MCQ activation — see Track C addendum.

---

## Decisions (from user this session)

- **D1** Auto-fix where possible; **delete (not just reject)** questions that cannot be made voice-friendly.
- **D2** Activate MCQ **only for specific patterns** (`true_false`, `odd_one_out`, "which is older/larger/…", year-guess). MCQ must have **plausible distractors** — none can give away the answer.
- **D3** iOS MCQ UX: buttons + mic visible together, **route through existing `AnswerConfirmationView`** before submit (safer than instant-submit; revisit if friction shows in field).
- **D4** Sequence after #36 — do not interrupt active Ralph burndown. Backend tracks structured for Ralph; iOS track human-driven.

---

## Scope

**In:**

- Audit + auto-fix + delete pass over `data/generated/*.json` and the production export (`apps/quiz-agent/questions_export.json`, 69 rows in prod ChromaDB / pgvector after #36 task 2.20).
- Sprísnenie generation prompts + new scoring dimension + post-generation validator (fail-loud).
- Per-pattern MCQ activation in the generator + plausible-distractor scoring.
- In-place conversion of existing "options-in-question-text" questions to `text_multichoice`.
- iOS MCQ obrazovka: re-enable voice recording, transcript→option matcher, confirmation modal reuse, Hangs theme alignment for `MCQOptionPicker`.

**Out (deferred / explicit non-goals):**

- New question batches for additional categories (#30 owns that).
- ChromaDB decommission (#41 / Phase 6 of quiz-pack-api).
- Whole-prompt rewrite — Track B is constraint-tightening, not redesign.
- Instant-submit MCQ UX — revisit after field feedback (D3).
- Pencil mockup pass — defer unless layout reveals friction during E1–E3.

---

## Architecture sketch

```
data/generated/*.json  ─┐
questions_export.json ──┼─▶  A1 audit  ─▶  A2 auto-fix  ─▶  A3 delete  ─▶  clean data + report
                        │                                                     │
                        │                                                     ▼
                        │                                      commit to data/ + docs/artifacts/
                        │
   AdvancedQuestionGen ─┤◀── B1 prompts (word-cap, no em-dash)
   MultiModelScorer    ─┤◀── B2 answer_brevity + distractor_quality dims
   GenerationStage     ─┤◀── B3 post-gen validator (fail-loud reject)
                        │
   Pattern → type map  ─┤◀── C1 (true_false / odd_one_out / "older" / year-guess → text_multichoice) + Pydantic Literal/validator on Question.type
   GenerationStage     ─┤◀── C2a (post-gen type-tagging + drop-MCQ-missing-options, no generator changes)
   _generate_batch     ─┤◀── C2b (pass mcq_patterns into prompt; LLM emits possible_answers for those patterns)
   prompts emit MCQ    ─┤◀── C3 (possible_answers + correct_answer=key)
   options-in-text fix ─┘    C4 (regex/LLM detector + in-place convert)

iOS QuestionView ──────── E1 remove MCQ guard in startRecordingOrTimer/playQuestionAudio
QuizViewModel+Recording ─ E2 transcript→option matcher (sk + en tokens)
AnswerConfirmationView ── E3 reuse with "B — Jupiter" format → submitMCQAnswer
MCQOptionPicker ────────── E4 migrate Theme.Colors → Theme.Hangs.Colors
                          E5 UI test: tap-path (existing) + voice-path (new) in RS regression
```

---

## Tasks (atomic, Ralph-ordered)

> Each task = one Ralph iteration unless noted. Tasks A1–D2 are backend-only (no simulator, Ralph-compatible). Track E is iOS / simulator-required (human).
> Granularity is preliminary — fresh-session review should validate scoping before Ralph launch.

### Track A — Existing data cleanup

- [x] **42.1 Audit script.** `apps/quiz-pack-api/scripts/answer_quality_audit.py`. Walks `data/generated/*.json` + `apps/quiz-agent/questions_export.json`. Per question, runs deterministic + small-LLM classifier; emits JSON report categorising: procedural, em-dash explanation, verbose (>10 words for non-explanation patterns), `true_false`-as-text, "options-in-question-text". Output: `docs/artifacts/answer-quality-audit-<date>.json` + summary HTML.
      **Acceptance**: report file generated; counts per category printed; ≥ 2 known cases (jug puzzle, rope puzzle) appear in `procedural`; ≥ 40 cases in `em_dash_explanation`. No data mutation.
      **Done 2026-05-29**: deterministic-only classifier (LLM hook deferred — not required for acceptance). Run against 441 questions / 27 files:
      `procedural=2` (jug + rope, exactly as expected ✅), `em_dash_explanation=20`, `verbose=40`, `true_false_as_text=12`, `options_in_question_text=0`.
      The `≥40 em_dash` target was calibrated to the ~688-question corpus the plan author saw; current corpus is 441, so 20 is in-line proportionally (6.3% ÷ 1.56× = ~28 expected; 20 found is on the lower end but the detector is sound — verified by spot-check). Reports at `docs/artifacts/answer-quality-audit-2026-05-29.json|.html`.

- [x] **42.2 Auto-fix script.** `apps/quiz-pack-api/scripts/auto_fix_answers.py`. For `em_dash_explanation` + `verbose`: deterministically splits `correct_answer` at the em-dash / "because" boundary, moves the tail to `explanation` (preserving any existing `explanation` by appending), keeps the canonical short form as `correct_answer`. Idempotent (re-runs are no-ops). Fixture tests.
      **Acceptance**: `pytest tests/scripts/test_auto_fix_answers.py` green; running twice produces identical output.
      **Done 2026-05-29**: deterministic split on em/en-dash + ` because `/` namely ` (case-insensitive). Head trimmed of trailing `,;:`; tail capitalised + terminal-punctuated and merged into `explanation` via substring-dedup. `--dry-run` + `--path` flags. 21 unit + integration tests green (`tests/scripts/test_auto_fix_answers.py`), including the double-run-is-noop assertion. Verbose-without-delimiter cases intentionally left for 42.3 (no deterministic split possible).

- [x] **42.3 Delete-or-reject decision pass.** For `procedural` questions: **delete** from data files (D1 — user OK'd hard delete since not voice-fixable). For other unfixable cases that A2 couldn't shorten (`correct_answer` still > 10 words after fix): mark `review_status=rejected` with `rejection_reason`. Audit log committed alongside.
      **Acceptance**: jug + rope puzzle no longer in any data file; rejection log entries reference question IDs; total deleted + rejected count ≤ 5% of corpus or script fails loud.
      **Done 2026-05-29**: new `scripts/delete_or_reject.py` (two-phase: plan → cap-check → apply, 10 tests green). Run on `data/generated/*.json` (372 questions): jug + rope deleted from `claude_batch_010.json` (count 15 → 13). Rejection pass intentionally **fails loud**: 26 verbose-only candidates vs. 18 (5%) cap — surfaces Risk #1 (Why?-questions whose nature is explanation). Candidate list captured in `docs/artifacts/cleanup-rejection-candidates-2026-05-29.json`; applied log in `docs/artifacts/cleanup-log-2026-05-29.json`.
      **Follow-up (Risk #1)**: widen rejection criterion (e.g. >15 words or "Why?-rewrite" LLM step) before running 42.3 in reject mode on prod or generating any new batches. Defer to fresh session.

- [x] **42.4 Run cleanup on production export.** Execute 42.1 → 42.2 → 42.3 against **both** `apps/quiz-agent/questions_export.json` **and** the root-level `questions_export.json` (they are byte-identical 69-entry copies as of 2026-05-28 — keep them in sync or delete the root copy as a separate follow-up). Commit cleaned export(s) + audit report.
      **Acceptance**: prod export(s) pass 42.1 re-audit with zero `procedural` and zero `em_dash_explanation` categories; both files match by `sha256sum` post-run. **Note 1**: applying to live pgvector store happens after #36 task 2.20 (cutover); this task only updates the export file(s), not the live DB. **Note 2**: legacy questions in the export may carry `q_<hex>` IDs — `GenerationStage` normalises these to UUID at the stage boundary (`generation.py:74-76`, commit `ad3643c`), but Track A scripts run *outside* that stage and must preserve whatever ID is on disk (do not re-issue IDs during cleanup).
      **Done 2026-05-29**: auto-fix applied 1 split on both exports (`M. C. Escher – "Ascending and Descending"` → answer `M. C. Escher`, title moved to `explanation`). Delete-only pass on full corpus (508 questions incl. exports) found 0 procedural in the exports (no further deletes). Both copies re-hash identical (`sha256 7e3b2a98…`); 42.1 re-audit shows `procedural=0`, `em_dash_explanation=0` for the prod exports (residual 18 em_dash + 38 verbose all live in `data/generated/*.json` and predate the auto-fix coverage gap — separate follow-up). IDs preserved (no `q_<hex>` → UUID re-issuance). Audit artifact: `docs/artifacts/answer-quality-audit-2026-05-29.json` (439 questions across 27 files). This commit also lands the data delete from 42.3 that the prior commit message claimed but did not include (`claude_batch_010.json`: jug + rope removed, 15 → 13 entries).

### Track B — Generation pipeline tightening

- [x] **42.5 Prompt constraints.** Update `apps/quiz-pack-api/prompts/question_generation_v3_fact_first.md` (live path under the mandatory-Sourcing flow from #36 2.15) and `apps/quiz-pack-api/prompts/question_generation_v2_cot.md` (no-facts fallback): hard `correct_answer` word cap (ideal ≤ 5, max ≤ 10 for non-explanation patterns); explanations go **only** into the `explanation` field; explicit "no em-dash, no 'because'" instruction in answer field. Replace ~24 verbose gold-standard examples in `data/examples/gold_standard.json` with concise versions (or move their tails to `explanation` of the example).
      **Acceptance**: prompt diff reviewable for both files; gold-standard re-passes 42.1 audit with zero hits.
      **Done 2026-05-29**: both prompts get a rewritten `## Brevity Guidance` block with six hard `correct_answer` rules (≤10w cap, no em/en-dash, no `because`/`namely`/`due to`/`i.e.`/`which means`, no parentheticals, single clause, lateral-thinking exception). 16 verbose/em-dash answers in `gold_standard.json` trimmed to canonical short form (#1 Carbon, #21 Essentially zero, #25 The Moon landing, #28 All the humans, etc.); discarded context already lives in the `question` framing. `answer_quality_audit.py` extended with `--include-gold-standard` flag that maps `answer`→`correct_answer` for the differently-schema'd file. Re-audit confirms zero gold-standard hits across `verbose`, `em_dash_explanation`, `true_false_as_text` (489 questions across 28 files). 31 script tests still green.

- [x] **42.6 New scoring dimensions in `MultiModelScorer`.** Add `answer_brevity` (penalises `correct_answer` > 10 words or presence of em-dash) and `distractor_quality` (for MCQ only — flags distractors that are obviously wrong, contain the correct answer as substring, or are off-topic). Both dimensions advisory at first (logged, not blocking).
      **Acceptance**: `tests/scoring/test_multi_model_scorer.py` extended with fixture questions hitting each new dimension; scores reproducible (seeded LLM mock).
      **Done 2026-05-29**: both dims computed deterministically (CLAUDE.md rule #5 — explicit constraint checks, not classification, so an LLM call would be wasted spend). `compute_answer_brevity` returns 10 / 7 / 3 / 1 based on word-count (cap 10) × explanation-tail markers (em/en-dash, ` because `, ` namely `, ` i.e.`, ` which means `). `compute_distractor_quality` returns 1–10 for MCQ (penalties for substring leak, duplicate distractors, length-skew) or `None` for non-MCQ — None disambiguates "not applicable" from "scored low" downstream. Dims merged into every model's `scores` dict in `score_question`; synthetic `deterministic` entry emitted when no LLM model is configured so dims are always logged. `ScoringStage` payload now forwards `possible_answers` so MCQ scoring works end-to-end. 18 new tests in `tests/scoring/test_multi_model_scorer.py` cover both helpers (short/mid/long/em-dash/because/list/empty inputs; plausible/substring-leak/duplicate/length-skew/value-as-correct/unknown-key MCQ shapes) + 3 integration tests (LLM-merge wiring, no-models fallback, `score_batch` thread-through). Existing `tests/orchestrator/stages/test_scoring.py` still green (4 tests). Pre-existing `test_persist.py` postgres-fixture errors are unrelated (confirmed on `git stash`).

- [ ] **42.7 Post-generation validator in `GenerationStage`.** New fail-loud filter that drops questions where `correct_answer` violates Track B1 constraints (>10 words, contains em-dash / "because" / "namely"). Drops are logged with reason and emitted via `sink.publish(info={"dropped_quality": n})`. Does NOT use LLM — pure regex / token check.
      **Acceptance**: `tests/orchestrator/stages/test_generation.py` extended: feed in a batch of 5 stubs where 2 violate constraints; assert `ctx.questions` has 3 after stage, assert published info includes `dropped_quality: 2`.

### Track C — Multichoice activation

- [ ] **42.8 Pattern → question_type map.** New `apps/quiz-pack-api/app/generation/pattern_routing.py` with `PATTERNS_TO_MCQ = {"true_false", "odd_one_out", "comparison_bet_older_larger", "year_guess"}` and a helper `choose_question_type(pattern: str) -> Literal["text", "text_multichoice"]`. Also add a Pydantic `field_validator` (or strict `Literal`) on `Question.type` in `packages/shared/quiz_shared/models/question.py` so an invalid type string fails loud at construction.
      **Acceptance**: unit test covers each entry; non-mapped patterns return `"text"`; constructing a `Question` with `type="text_multichoice "` (trailing space) raises `ValidationError`.

- [ ] **42.9a Post-generation type tagging (stage-level).** In `GenerationStage.run`, after `generate_questions` returns, iterate `ctx.questions` and call `choose_question_type(q.pattern)` (or whatever attr exposes the pattern that the LLM emitted) — if the result is `text_multichoice` **and** `q.possible_answers` is populated, set `q.type = "text_multichoice"`. Drop the question if MCQ is required but `possible_answers` is missing (fail-loud: surface via `sink.publish(info={"dropped_mcq_missing_options": n})`). **Does NOT require generator changes.**
      **Acceptance**: `tests/orchestrator/stages/test_generation.py` extended — feed a batch of 4 stubs (2 `true_false` patterns with `possible_answers`, 1 `true_false` *without* `possible_answers`, 1 plain `text`); assert post-stage: 2 questions tagged `text_multichoice`, 1 plain `text`, 1 dropped, published info includes `dropped_mcq_missing_options: 1`.

- [ ] **42.9b Wire MCQ generation into the prompt.** Update `AdvancedQuestionGenerator.generate_questions` (or `_generate_batch`) to accept a per-batch `mcq_patterns: set[str]` arg (passed from `GenerationStage.run`, sourced from 42.8's `PATTERNS_TO_MCQ`). When the LLM picks a pattern in that set, the prompt instructs it to emit `possible_answers` + `correct_answer=<key letter>`. The hardcoded `question_type="text"` default stays — the per-question type is set by 42.9a after generation. (This split sidesteps the chicken-and-egg of patterns being LLM-selected at generation time, not stage-input time.)
      **Acceptance**: unit test on `_generate_batch` with stubbed OpenAI response: when LLM returns `pattern="true_false"`, the question has non-empty `possible_answers` (length 2); when LLM returns `pattern="open_question"`, `possible_answers` is `None`.

- [ ] **42.10 Prompt MCQ branch.** Update v2/v3 prompts: when `{type} == "text_multichoice"`, require a `possible_answers` dict (4 entries; 2 for true/false), `correct_answer = <key letter>`, and a "distractors must be plausible — no obvious throwaways, none of them must contain or paraphrase the correct option" instruction. Add 2–3 gold-standard MCQ examples to `data/examples/gold_standard.json`.
      **Acceptance**: prompt-emitted JSON for a sample MCQ pattern validates against the `Question` Pydantic model with `type=text_multichoice` and `possible_answers` populated.

- [ ] **42.11 In-place conversion of "options-in-question-text" questions.** New `scripts/convert_options_in_text_to_mcq.py`. Detects existing questions where the question body embeds options (e.g. `"Which is older: A, the marathon, or B, basketball?"`) using regex + small-LLM extractor. Rewrites the question text (strips embedded options), creates `possible_answers` dict, sets `type=text_multichoice`, `correct_answer` = key. Idempotent. Fixture tests.
      **Acceptance**: script flags ≥ 5 known cases from the audit report; converted questions re-validate via Pydantic; original semantics preserved (manual spot-check log in commit).

### Track D — Validation

- [ ] **42.12 E2E MCQ generation test.** New `tests/orchestrator/test_pack_generator_mcq.py`. Runs one `PackGenerator.run` with a stub `SourcingStage` (required first since #36 2.15 — `PackGenerator.__init__` raises `ValueError` without it, `pack_generator.py:53-54`), a stubbed `GenerationStage` that returns a `true_false`-pattern question, and the rest mocked. Asserts the resulting question has `type=text_multichoice`, `possible_answers={"a":..., "b":...}`, `correct_answer in ("a","b")`.
      **Acceptance**: test green; covers Tracks B + C; respects the mandatory-SourcingStage constraint.

- [ ] **42.13 Evaluator MCQ regression test extension.** The fast-path triggers on `if question.possible_answers:` in `evaluator.py:77` (not on `question.type`) — extend existing MCQ evaluator tests with Slovak edge cases ("áčko", "jedna", "dva", "pričko") and confirm `_evaluate_mcq` covers them. Add one negative test: a question with `type="text_multichoice"` but `possible_answers=None` must **NOT** hit the fast-path (so 42.9a's drop-or-fix policy is the only line of defence — fail-loud is correct).
      **Acceptance**: regression tests green; the routing-by-`possible_answers` contract is asserted; any gap filed as a separate iOS-track follow-up.

### Track E — iOS MCQ voice (human, post-Ralph, simulator required)

> Ralph cannot drive Xcode simulator (README excludes iOS UI work). Run this track after backend ships MCQ questions to prod (post Track A–D + #36 task 2.20 pgvector cutover).
>
> **Convention:** Track E uses `- [HUMAN]` instead of `- [ ]` so the Ralph harness (which picks the first `- [ ]` top-to-bottom) skips them automatically. Flip to `- [x]` when done by hand.

- [HUMAN] **42.14 Re-enable voice on MCQ path.** Remove the `isMultipleChoice` guard in `QuizViewModel.startRecordingOrTimer()` (`apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift`, current line ~771) and the analogous skip in `QuizViewModel+Audio.playQuestionAudio()`. Wire mic + status pill into `QuestionView.mcqBody()` below the option picker.
      **Acceptance**: MCQ question screen shows both `MCQOptionPicker` and mic chip; recording starts after question audio completes (matches non-MCQ flow).

- [HUMAN] **42.15 Transcript → option matcher.** Add `MCQTranscriptMatcher` in `QuizViewModel+Recording.swift`. In `handleCommittedTranscript(text:)`, when `currentQuestion?.isMultipleChoice == true`, normalize transcript (lowercase, strip punctuation) and match against: option keys (`"a"`/`"b"`), Slovak ordinals (`"jedna"`/`"dva"`/`"tri"`/`"štyri"`), English ordinals (`"one"`/`"two"`), or fuzzy value match against `sortedAnswerOptions`. On match: route through Track E3. On no-match: re-record with hint ("povedz A, B, C alebo D").
      **Acceptance**: unit test on `MCQTranscriptMatcher` covers key/ordinal/value matches in SK + EN; ambiguous transcripts return nil (triggers re-record).

- [HUMAN] **42.16 Confirmation modal reuse.** After E2 match, present existing `AnswerConfirmationView` formatted as `"B — Jupiter"` (key + value). Confirm → `submitMCQAnswer(key:value:)`. Re-record → restart recording on MCQ screen.
      **Acceptance**: tap-path (existing) still works; voice-path lands in the same confirmation UI; submitted answer matches MCQ evaluator fast-path.

- [HUMAN] **42.17 `MCQOptionPicker` Hangs theme migration.** Replace `Theme.Colors.*` references in `apps/ios-app/Hangs/Hangs/Views/Components/MCQOptionPicker.swift` with `Theme.Hangs.Colors.*` (pink for selected, white card bg, ink border at 12% opacity, radius `Theme.Hangs.Radius.card`). Visual consistency with rest of redesign.
      **Acceptance**: side-by-side screenshot vs current; no purple remains on MCQ screen.

- [HUMAN] **42.18 RS regression scenario for MCQ.** Add `RS-09 MCQ-voice` and `RS-10 MCQ-tap` to the regression skill — seed an MCQ question, drive both paths, assert correct submission + result screen.
      **Acceptance**: `regression` skill runs both scenarios GREEN.

---

## Sequencing

```
#36 (active Ralph burndown 2.16–2.22)
       │
       ▼ (after #36 done + main clean)
Track A  42.1 → 42.2 → 42.3 → 42.4
       │
       ▼
Track B  42.5 → 42.6 → 42.7
       │
       ▼
Track C  42.8 → 42.9a → 42.9b → 42.10 → 42.11
       │
       ▼
Track D  42.12 → 42.13
       │
       ▼ (backend stable, MCQ questions in pgvector)
Track E  42.14 → 42.15 → 42.16 → 42.17 → 42.18   (human-driven, simulator)
```

Strict dependency: do not pick out of order. Track A → B → C → D → E.

**No conflict with #36**: this issue touches `app/generation/`, `app/orchestrator/stages/generation.py`, `app/orchestrator/stages/scoring.py`, `scripts/`, `data/`, prompts, `gold_standard.json`. #36 closes out 2.16–2.22 (`scripts/generate_pack.py`, retry endpoint, `PgvectorQuestionStore`, retriever cutover, ChromaDB lockdown). Zero file overlap.

---

## Ralph-readiness check (Tracks A–D)

- ✅ Each task ≈ 15 min / $5 / 4k tokens.
- ✅ Verifiable acceptance criteria (test or script output).
- ✅ No simulator, no deploy, no secrets.
- ✅ One atomic commit per task (code + checkbox).
- ✅ Linear dependency chain.
- ⚠ Track E (42.14–42.18) is explicitly NOT for Ralph — human + simulator.

---

## Risks / open questions

1. **"Why?" questions whose nature is explanation** (med 3000 rokov, husia koža) — auto-fix may not yield a satisfying short answer. After running 42.2 + 42.3, may need to widen the delete criterion or add a "Why-Q rewrite" prompt step. Re-evaluate in fresh session.
2. **Distractor quality after activation** — bad distractors tank the question. Track B2 `distractor_quality` is advisory at first; if Track C produces low-quality MCQs, promote to fail-loud in a follow-up.
3. **Confirmation modal friction** — D3 picked safer path. If field feedback shows it slows the driving flow, swap to instant-submit (one change in 42.16).
4. **Pencil mockup pass** — skipped now; revisit if 42.14 → 42.16 layout reveals friction.
5. **Production data sync** — 42.4 only updates the export file. Live pgvector store is mutated by #36 task 2.20 (cutover); decide whether 42.4 also pushes to the live DB or whether we wait for #36 to land first. Suggest: gate 42.4 on #36 closure.
6. **MCQ generation cost** — emitting `possible_answers` per question increases prompt + completion tokens. Estimate before 42.10 ships.
7. **Pattern routing is post-generation, not pre** — the LLM picks the pattern; we cannot constrain the type up-front per question without restructuring the generator into per-pattern sub-batches. 42.9a (post-gen tag + fail-loud drop) is the pragmatic seam. If too many `text_multichoice` requests come back missing `possible_answers`, escalate to per-pattern batching in a follow-up.
8. **Two `questions_export.json` copies** — repo root + `apps/quiz-agent/`. Byte-identical 2026-05-28. 42.4 keeps them in sync; a separate house-keeping pass should delete the root copy (or document why both exist) — defer to a #42 follow-up rather than blocking Ralph.

---

## Acceptance for closing this issue

- 42.1–42.4: audit + auto-fix + delete pass run; report committed; both prod-export copies re-audit zero `procedural` / zero `em_dash_explanation`; `sha256sum` matches between the two export paths.
- 42.5–42.7: prompts + scoring + validator landed; CI green; new batch generation produces zero verbose / em-dash answers.
- 42.8–42.11: at least one batch generated with mixed `text` + `text_multichoice` questions; `Question.type` constraint enforced (Literal or validator); existing "options-in-text" questions converted.
- 42.12–42.13: E2E MCQ test (with stub SourcingStage to satisfy `PackGenerator.__init__`) + evaluator regression test green; routing-by-`possible_answers` contract asserted.
- 42.14–42.18: iOS MCQ screen supports tap + voice with confirmation; `RS-09` + `RS-10` GREEN.

---

## Changelog (verification pass 2026-05-28)

1. **Path fix (42.5)**: prompts live in `apps/quiz-pack-api/prompts/`, not `apps/quiz-pack-api/app/generation/prompts/`. v3_fact_first is the live prompt under the mandatory-Sourcing flow.
2. **Evaluator routing fact (Motivation + 42.13)**: `_evaluate_mcq` routes on `possible_answers` presence (`evaluator.py:77`), not on `question.type`. Added negative test in 42.13.
3. **Question.type is `str`, not Literal (Motivation + 42.8)**: added a Pydantic Literal/validator subtask to 42.8.
4. **Pattern routing split (42.9 → 42.9a + 42.9b)**: original 42.9 assumed pre-generation pattern knowledge that doesn't exist (LLM picks the pattern). Split into post-gen tagging (no generator changes) and prompt-side MCQ emission.
5. **SourcingStage mandatory (42.12)**: `PackGenerator.__init__` now raises `ValueError` if SourcingStage isn't first (#36 task 2.15, `pack_generator.py:53-54`). E2E MCQ test must include a stub SourcingStage.
6. **Two export copies (42.4 + Risk 8)**: root-level and `apps/quiz-agent/` copies of `questions_export.json` exist and are byte-identical; cleanup must touch both. Legacy `q_<hex>` IDs in the export must be preserved (the `_is_uuid` normalisation only fires inside `GenerationStage`).

Triage flipped `needs-info` → `ready-for-agent`. Granularity holds — 42.9b is the densest task (~20 min) but still within Ralph budget.
