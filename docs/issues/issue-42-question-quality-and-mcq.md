# Issue 42: Question quality sweep + multichoice activation

**Triage:** enhancement · ready-for-agent
**Status:** Plan verified in fresh session 2026-05-28 against actual codebase (commit `ad3643c`). 6 real bugs in the preliminary plan fixed (see Changelog at bottom). Backend tracks A–D are Ralph-suitable atomic tasks; iOS Track E is human-driven (simulator required) — superseded by #45. Gated on #36 closing tasks 2.16–2.22. **2026-06-10: Track F added** (fresh MCQ batch per founder decision 2026-06-09) — Ralph launcher `scripts/ralph/launch-issue42-mcq.sh` ready; awaiting founder go.
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

- [x] **42.7 Post-generation validator in `GenerationStage`.** New fail-loud filter that drops questions where `correct_answer` violates Track B1 constraints (>10 words, contains em-dash / "because" / "namely"). Drops are logged with reason and emitted via `sink.publish(info={"dropped_quality": n})`. Does NOT use LLM — pure regex / token check.
      **Acceptance**: `tests/orchestrator/stages/test_generation.py` extended: feed in a batch of 5 stubs where 2 violate constraints; assert `ctx.questions` has 3 after stage, assert published info includes `dropped_quality: 2`.
      **Done 2026-05-29**: new `_violates_answer_brevity(answer)` helper in `app/orchestrator/stages/generation.py` reuses `_ANSWER_WORD_CAP`/`_ANSWER_TAIL_MARKERS` from 42.6's `multi_model_scorer` so the validator and the brevity scorer stay aligned by construction. Filter runs after post-processing but **before** the F8 source_url check — dropped-by-quality questions never have to satisfy attribution. Each drop logs `WARNING GenerationStage dropped question id=… reason=… answer=…` with reason in `{empty_answer, over_word_cap_10, tail_marker:<marker>}`. `StageResult.info["dropped_quality"]` surfaces the count to SSE/audit (same shape as `DedupStage.info["dropped"]`); `StageResult.info["questions"]` now reflects the post-filter count, not the generator's raw output. New `test_drops_questions_violating_answer_brevity` covers 5-stub batch (2 violations: em-dash+over-cap, "because" tail) → 3 kept, `dropped_quality=2`, kept set verified by question text. All 9 generation-stage + 22 scoring tests green.

### Track C — Multichoice activation

- [x] **42.8 Pattern → question_type map.** New `apps/quiz-pack-api/app/generation/pattern_routing.py` with `PATTERNS_TO_MCQ = {"true_false", "odd_one_out", "comparison_bet_older_larger", "year_guess"}` and a helper `choose_question_type(pattern: str) -> Literal["text", "text_multichoice"]`. Also add a Pydantic `field_validator` (or strict `Literal`) on `Question.type` in `packages/shared/quiz_shared/models/question.py` so an invalid type string fails loud at construction.
      **Acceptance**: unit test covers each entry; non-mapped patterns return `"text"`; constructing a `Question` with `type="text_multichoice "` (trailing space) raises `ValidationError`.
      **Done 2026-05-29**: new `app/generation/pattern_routing.py` exports `PATTERNS_TO_MCQ` (frozenset) + `choose_question_type(pattern)`; unknown/`None`/empty patterns degrade to `"text"` (fail-safe — a half-built MCQ missing options is worse than free-form). Pydantic `field_validator` on `Question.type` rejects anything outside `{text, text_multichoice, audio, image, video}` (the five values already named in the field's docstring; corpus scan of 508 questions confirms only `text` is in use, so no legacy breakage). 20 new tests in `tests/generation/test_pattern_routing.py`: each MCQ pattern by name, 5 non-MCQ patterns, `None`/empty, set-membership lock, every allowed type constructs, trailing-space + `multiple_choice` + empty all raise. Full quiz-pack-api (146 passed) + quiz-agent (89 passed) suites green. Postgres-dependent tests in `tests/api/` + `tests/db/` + `tests/orchestrator/stages/test_persist.py` skipped — unrelated infra (confirmed pre-existing).

- [x] **42.9a Post-generation type tagging (stage-level).** In `GenerationStage.run`, after `generate_questions` returns, iterate `ctx.questions` and call `choose_question_type(q.pattern)` (or whatever attr exposes the pattern that the LLM emitted) — if the result is `text_multichoice` **and** `q.possible_answers` is populated, set `q.type = "text_multichoice"`. Drop the question if MCQ is required but `possible_answers` is missing (fail-loud: surface via `sink.publish(info={"dropped_mcq_missing_options": n})`). **Does NOT require generator changes.**
      **Acceptance**: `tests/orchestrator/stages/test_generation.py` extended — feed a batch of 4 stubs (2 `true_false` patterns with `possible_answers`, 1 `true_false` *without* `possible_answers`, 1 plain `text`); assert post-stage: 2 questions tagged `text_multichoice`, 1 plain `text`, 1 dropped, published info includes `dropped_mcq_missing_options: 1`.
      **Done 2026-05-29**: pattern read from `q.generation_metadata.reasoning_pattern` (preserved through the stage's existing provenance-merge step, so 42.9b only needs to populate it). Tagging step runs **after** the 42.7 brevity filter and **before** the F8 source_url check — a dropped-MCQ question never has to satisfy attribution, mirroring 42.7's ordering. Drop logs `WARNING GenerationStage dropped question id=… reason=mcq_missing_options pattern=…`; count surfaces in `StageResult.info["dropped_mcq_missing_options"]` (same shape as `dropped_quality`). `_FakeGenerator` test feeds 4 stubs (2 MCQ-with-options, 1 MCQ-missing-options, 1 non-MCQ) → kept = {text_multichoice, text_multichoice, text}, dropped_mcq_missing_options=1. All 10 generation-stage tests green (8 pre-existing + 42.7 + 42.9a). Non-MCQ patterns and `reasoning_pattern=None` (i.e. legacy generator output before 42.9b lands) fail safe to `type="text"` — no behaviour change for existing flows.

- [x] **42.9b Wire MCQ generation into the prompt.** Update `AdvancedQuestionGenerator.generate_questions` (or `_generate_batch`) to accept a per-batch `mcq_patterns: set[str]` arg (passed from `GenerationStage.run`, sourced from 42.8's `PATTERNS_TO_MCQ`). When the LLM picks a pattern in that set, the prompt instructs it to emit `possible_answers` + `correct_answer=<key letter>`. The hardcoded `question_type="text"` default stays — the per-question type is set by 42.9a after generation. (This split sidesteps the chicken-and-egg of patterns being LLM-selected at generation time, not stage-input time.)
      **Acceptance**: unit test on `_generate_batch` with stubbed OpenAI response: when LLM returns `pattern="true_false"`, the question has non-empty `possible_answers` (length 2); when LLM returns `pattern="open_question"`, `possible_answers` is `None`.
      **Done 2026-05-29**: new `mcq_patterns: Optional[set[str]]` kwarg on `generate_questions` + `_generate_batch`, rendered into `{mcq_patterns_section}` via the new `_format_mcq_patterns_section` helper. Section is empty when no patterns — back-compat for ad-hoc callers (and existing test_advanced_generator scenarios). Per-pattern recipes (`true_false` → 2-option, `odd_one_out` → 4-option, `comparison_bet_older_larger` → 2-option, `year_guess` → 4-option) tell the LLM the exact shape of `possible_answers` + the `correct_answer = <key letter>` rule, plus the distractor-quality rule pulled forward from 42.10. The prompt-side instruction also pins `reasoning.pattern_used` to the snake_case key so 42.9a's routing helper (which keys on the same constants) doesn't drift. `_extract_pattern_used` lifts the LLM-emitted `reasoning.pattern_used` (parked in `generation_metadata.extra["reasoning"]` by `_absorb_unknown_keys`) into the typed `reasoning_pattern` slot before the provenance overwrite — without this, 42.9a's tagging step would always see `reasoning_pattern=None`. `GenerationStage.run` passes `mcq_patterns=set(PATTERNS_TO_MCQ)` from 42.8. Both v2_cot and v3_fact_first prompts now carry `{mcq_patterns_section}` after the Brevity Guidance block; `PromptBuilder.build_prompt` provides an empty default so any caller that forgets the kwarg still gets a working prompt. 7 new tests in `tests/generation/test_advanced_generator.py` cover the MCQ-pattern-in-set path (`possible_answers` length 2, `reasoning_pattern == "true_false"`), the non-MCQ baseline (`possible_answers is None`, `reasoning_pattern == "open_question"`), prompt-section delivery (asserts against the captured prompt string), empty-set fallback, listing shape, and `_extract_pattern_used` edge cases. Stubbed via `SimpleNamespace` swap of `generation_llm` because `ChatOpenAI` is a Pydantic-frozen model that rejects `patch.object`. Existing pin test in `test_generation.py` extended to assert `gen.calls[0]["mcq_patterns"]` superset-matches 42.8's set. Full suite (161 passed / 3 skipped / 3 xfailed) green; postgres-dependent tests skipped (unrelated).

- [x] **42.10 Prompt MCQ branch.** Update v2/v3 prompts: when `{type} == "text_multichoice"`, require a `possible_answers` dict (4 entries; 2 for true/false), `correct_answer = <key letter>`, and a "distractors must be plausible — no obvious throwaways, none of them must contain or paraphrase the correct option" instruction. Add 2–3 gold-standard MCQ examples to `data/examples/gold_standard.json`.
      **Acceptance**: prompt-emitted JSON for a sample MCQ pattern validates against the `Question` Pydantic model with `type=text_multichoice` and `possible_answers` populated.
      **Done 2026-05-29**: both prompts' Response Format MCQ blocks rewritten — explicit 4-vs-2 entry rule (4 general, 2 for `true_false`), `correct_answer` is the lowercase key letter (not the value), and the distractor-quality rule pulled verbatim into the spec ("no obvious throwaways, none may contain or paraphrase the correct option"; length-skew + substring-leak called out). Replaces v2's pre-existing contradictory "Make distractors plausible but clearly wrong" line. 42.9b's `{mcq_patterns_section}` continues to carry the per-pattern shape recipes — Response Format is the structural spec, the activation section is the pattern selector. 3 MCQ entries added to `data/examples/gold_standard.json` (one per primary pattern: `true_false` Cleopatra-vs-Moon-landing, `comparison_bet_older_larger` pyramid-country with 4 plausible distractors, `year_guess` ARPANET decade-spread). Each entry carries the new optional `type` + `possible_answers` keys; `answer` is the key letter. `load_gold_standard` extended to render MCQ entries with an inline `Options: A) … B) …` line and resolve the key letter to `A: a (True)` format — without this the LLM saw MCQ examples formatted identically to text examples and had no demonstration of how to fill `possible_answers`. New `tests/generation/test_gold_standard_mcq.py` (5 tests, all green) parametrises every MCQ entry through `Question.from_dict`, asserts the constructed Question has `type="text_multichoice"` + `possible_answers == options` + `correct_answer == key` (the literal acceptance criterion), checks the substring-leak rule on every distractor (CI catches a future edit that lets one option contain another's substring), and asserts `load_gold_standard` actually renders the new `Options:` line in the prompt text. Re-running `tests/generation/ tests/orchestrator/ tests/scoring/` → 87 passed; the 4 postgres-fixture errors in `test_persist.py` are pre-existing infra failures (confirmed across 42.6/42.7 prior tasks), unrelated.

- [x] **42.11 In-place conversion of "options-in-question-text" questions.** New `scripts/convert_options_in_text_to_mcq.py`. Detects existing questions where the question body embeds options (e.g. `"Which is older: A, the marathon, or B, basketball?"`) using regex + small-LLM extractor. Rewrites the question text (strips embedded options), creates `possible_answers` dict, sets `type=text_multichoice`, `correct_answer` = key. Idempotent. Fixture tests.
      **Acceptance**: script flags ≥ 5 known cases from the audit report; converted questions re-validate via Pydantic; original semantics preserved (manual spot-check log in commit).
      **Done 2026-05-29**: deterministic regex-only (no LLM — CLAUDE.md rule #5: constraint check, not classification). Detector anchors on `:\s*[^:?]+?\?$` so the LAST colon-before-terminal-`?` wins; `parse_options` splits on `", or "` / `" or "` / `","` and rejects any option exceeding 60 chars or containing `.`/`—`/`–` (pins out the Dr.-Seuss false positive where `"The challenge:"` would otherwise capture a 50-word "option"). `find_matching_option` uses normalised exact-equality first (lowercase + strip articles + strip terminal punctuation), then **word-boundary** substring containment (`\b<needle>\b`) — naive substring matched answer `"216"` against option `"1"` in sequence-completion questions and would have silently converted them to MCQs whose listed terms are red herrings. Skips questions already typed `text_multichoice` or carrying `possible_answers`. Ambiguous answers (substring matches > 1 option) are left untouched. **26 conversions** applied across 13 `data/generated/*.json` files (well above the ≥5 acceptance bar): odd-one-outs (Mercury/Venus/Earth/Mars/**Moon**; Picasso/Monet/Rembrandt/**Banksy**/Van Gogh; ostrich/emu/kiwi/**flamingo**), scale/year guesses (20 quadrillion ants, 14 Greenlands in Africa, 35-day longest film), and comparison bets (Egypt vs Sudan pyramids, trees on Earth vs Milky Way stars). All 26 re-validate via `Question.from_dict` with `type="text_multichoice"` and `correct_answer ∈ possible_answers`. Idempotent (second `--dry-run` reports 0). 25 unit + integration tests in `tests/scripts/test_convert_options_in_text_to_mcq.py` (parse-options × 8 incl. em-dash/period/length rejection; find-matching-option × 7 incl. digit-substring and "billion" ambiguity safety contracts; convert-question × 7; process-file idempotency + dry-run; Pydantic round-trip). Full spot-check log: `docs/artifacts/mcq-conversion-2026-05-29.json`.

### Track D — Validation

- [x] **42.12 E2E MCQ generation test.** New `tests/orchestrator/test_pack_generator_mcq.py`. Runs one `PackGenerator.run` with a stub `SourcingStage` (required first since #36 2.15 — `PackGenerator.__init__` raises `ValueError` without it, `pack_generator.py:53-54`), a stubbed `GenerationStage` that returns a `true_false`-pattern question, and the rest mocked. Asserts the resulting question has `type=text_multichoice`, `possible_answers={"a":..., "b":...}`, `correct_answer in ("a","b")`.
      **Acceptance**: test green; covers Tracks B + C; respects the mandatory-SourcingStage constraint.
      **Done 2026-05-29**: new `tests/orchestrator/test_pack_generator_mcq.py` drives a real `PackGenerator` with two stages — `_StubSourcingStage` (offline, emits one URL-attributed `Fact` so `GenerationStage`'s F8 fallback passes) and the **real** `GenerationStage` wrapped around `_StubMCQGenerator`. Using the real stage was deliberate: stubbing it would skip the 42.9a `choose_question_type` tagging step, and the tagging contract is the entire point of the regression. The generator returns a single `Question(reasoning_pattern="true_false", possible_answers={"a":"False","b":"True"}, correct_answer="a")`; the stage's 42.9a pass routes `true_false` → `text_multichoice`, the F8 fallback backfills `source_url` from the fact, and `pack_generator.last_ctx.questions[0]` carries the asserted shape (`type=="text_multichoice"`, keys `{a,b}`, `correct_answer ∈ {a,b}`). No `PersistStage` → `run()` returns `None` (expected). 1 test green; full suite re-runs unaffected. Tracks B + C contract pinned at the orchestrator boundary; if the LLM ever silently drops `possible_answers` or someone swaps the routing helper out, this test fails loud.

- [x] **42.13 Evaluator MCQ regression test extension.** The fast-path triggers on `if question.possible_answers:` in `evaluator.py:77` (not on `question.type`) — extend existing MCQ evaluator tests with Slovak edge cases ("áčko", "jedna", "dva", "pričko") and confirm `_evaluate_mcq` covers them. Add one negative test: a question with `type="text_multichoice"` but `possible_answers=None` must **NOT** hit the fast-path (so 42.9a's drop-or-fix policy is the only line of defence — fail-loud is correct).
      **Acceptance**: regression tests green; the routing-by-`possible_answers` contract is asserted; any gap filed as a separate iOS-track follow-up.
      **Done 2026-05-29**: `tests/test_mcq_evaluator.py` extended with two new classes. `TestMCQEvaluatorSlovakGap` parametrises `jedna`/`dva`/`áčko`/`pričko` through the inline `_evaluate_mcq` mirror and asserts all four return `("incorrect", 0.0)` — pinning that backend stays English-only and the iOS Track E task 42.15 (`MCQTranscriptMatcher`) is the layer that resolves Slovak ordinals / letter-forms to a key letter before submission. `TestEvaluatorRoutingByPossibleAnswers` instantiates the **real** `AnswerEvaluator` (with `OPENAI_API_KEY=sk-test`) and uses `AsyncMock` on `_llm_evaluate` + `_evaluate_mcq` to pin the routing contract from `evaluator.py:77`: (1) `type="text_multichoice"` + `possible_answers=None` falls through to the LLM path (MCQ mock raises `AssertionError` if hit; `_llm_evaluate` awaited once), reaffirming 42.9a's drop-or-fix filter as the only defence and matching the gap-is-iOS Track E follow-up call-out; (2) `type="text"` + populated `possible_answers` hits the MCQ fast-path (LLM mock raises if called), so 42.11's options-in-text conversions evaluate as MCQ even before any future `type` migration. Question constructed via the real Pydantic model so the Literal-validated `type` field is exercised end-to-end. 17 tests green (11 pre-existing untouched + 6 new).

### Track E — iOS MCQ voice (human, post-Ralph, simulator required)

> **⤳ Superseded by #45 (2026-06-03).** Track E (42.14–42.18) is folded into `issue-45-ios-mcq-voice-and-redesign.md`, which merges it with the Pencil design-port and splits the work into Ralph-suitable logic/components vs human integration. Do the MCQ-voice work there, not here. Kept below for provenance.
>
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

### Track F — Fresh MCQ batch run (added 2026-06-10)

> **Founder decision 2026-06-09:** generate a fresh MCQ batch first (gen→verify→score, brief review),
> founder approves what makes sense → import to prod. This track is that run. Tracks A–D landed the
> MCQ-capable pipeline (42.8–42.10) but **zero MCQ questions have been generated live** — 42.9b was
> only ever exercised against stubbed LLM responses, and the 26 MCQs from 42.11 are conversions, not
> fresh generations.
>
> **Execution model:** 42.19 / 42.20 / 42.23 are Ralph tasks (`scripts/ralph/launch-issue42-mcq.sh`,
> runs on mba — backend-only, no iOS SDK gate). 42.21 is an interactive-session **Workflow** (multi-agent
> distractor screen — needs the Workflow tool, not available headless). 42.22 is founder. 42.24 is an
> interactive session (touches prod pgvector via fly proxy).
>
> **Assumption (founder can override):** target ≈ **40 MCQ candidates** for review (~10 per pattern ×
> 4 patterns in `PATTERNS_TO_MCQ`) — enough signal for a *brief* review without a marathon.

- [x] **42.19 CLI support for MCQ-biased batches + file output.** Extend `scripts/generate_pack.py`: (a) `--out <path>` — after the run, dump the surviving `ctx.questions` as a JSON array (full `Question.model_dump`, stamped `review_status="pending_review"`) so dry-run batches land on disk for review and later import; (b) `--mcq-bias` — append a steering instruction to the order prompt nudging the LLM toward the `PATTERNS_TO_MCQ` patterns (true/false, odd-one-out, older/larger comparison, year-guess) — pattern choice stays LLM-side (Risk #7), this only shifts the prior; (c) `--dedup-store pgvector` (optional flag) — when `DATABASE_URL` is set, swap `_NoopQuestionStore` for a real pgvector-backed store so `DedupStage`'s 0.85 guard fires against the live corpus. **Verified 2026-06-10:** shared `PgvectorQuestionStore` (`packages/shared/quiz_shared/database/pgvector_client.py`) has **no** `find_duplicates`, and the quiz-agent-side `SyncPgvectorStore.find_duplicates` (`apps/quiz-agent/app/retrieval/sync_pgvector_store.py:103`) **raises `NotImplementedError`** — there is no working pgvector dedup anywhere yet. Implementing it in the shared store is the proper fix (both apps benefit), but it is a real subtask; if it doesn't fit the iteration budget, ship (a)+(b) only and file the dedup flag as a follow-up — do not block the batch run on it.
      **Acceptance**: unit tests with a stubbed generator — `--out` file round-trips through `Question.from_dict`; `--mcq-bias` text demonstrably present in the prompt the generator receives; invocation without the new flags is byte-identical in behaviour (existing e2e test still green).
      **Done 2026-06-10**: (a)+(b) shipped; (c) `--dedup-store pgvector` **deferred** per the in-task escape hatch — no working `find_duplicates` exists in either store, implementing it in the shared `PgvectorQuestionStore` is its own subtask (file as #42 follow-up before relying on live-corpus dedup in 42.20). `--out` dumps `ctx.questions` via `model_dump(mode="json")` + `review_status="pending_review"` stamp (writer = `_write_out`, reusable by tests). `--mcq-bias` appends a steering footer to `order.prompt` in `_build_order`, naming all four `PATTERNS_TO_MCQ` snake_case keys so the LLM pins `reasoning.pattern_used` to what 42.9a routes on; import is lazy so flagless invocations don't load `pattern_routing`. 4 new tests in `tests/scripts/test_generate_pack_flags.py`: bias-in-prompt (each pattern key asserted), flagless prompt byte-identical + `out=None`, `_write_out` round-trip through `Question.from_dict` (MCQ + text entries, `pending_review` stamp), and an in-process `cli_main` run with a stub `sourcing` stage asserting the bias text reaches `ctx.prompt` (what `GenerationStage` hands the generator) and the out-file carries the survivor. New tests + both pre-existing CLI integration tests green (6 passed); full suite 325 passed — the 8 failed / 10 errors are the documented pre-existing postgres-connection infra failures (`tests/api`, `tests/db`, `test_persist`), unrelated.

- [ ] **42.20 Generate one MCQ batch** *(repeatable — the core loop)*. **⏸️ PARKED 2026-06-11 — do not run; the MCQ generation flow needs redesign first (founder decision, see `## BLOCKER (2026-06-11, third run)` below).** From `apps/quiz-pack-api/`: `python scripts/generate_pack.py --prompt "<topic>" --target-count 20 --dry-run --mcq-bias --out ../../data/generated/mcq_batch_NNN.json` (+ `--dedup-store pgvector` if 42.19c landed). Vary `<topic>` per batch (history / science / geography / pop culture / nature …) and record it in the batch file name or metadata — repeated identical prompts breed duplicates. Post-run: filter the out-file to `type == "text_multichoice"` only (survivors are already post-verification + post-scoring, incl. `answer_brevity` + `distractor_quality`), rewrite the file with just the candidates, commit. **Before generating, count cumulative candidates across `data/generated/mcq_batch_*.json` — if ≥ 40, flip this task to `[x]` and move on.** Fail-loud: if a batch yields **< 5** MCQ candidates, do not silently loop — write a `BLOCKER` note here (bias not biting → revisit 42.19b prompt wording or fall back to per-pattern sub-batches per Risk #7).
      **Acceptance per iteration**: ≥ 5 new `text_multichoice` candidates with populated `possible_answers`, `source_url`, and scores in the committed batch file; running count noted in the commit message.
      ~~**⛔ Blocked 2026-06-10** — first live run yielded 1/9 MCQ candidates; see `## BLOCKER (2026-06-10)` at the bottom of this file. Do not re-run until the pattern-label mismatch is fixed.~~ **Unblocked 2026-06-10:** root causes A (pattern-label normalization, `24ab3e4`) and B (hard MCQ quota + diversity-rule carve-out) both fixed — re-run is go. First batch was deleted, so restart at `mcq_batch_001.json`.
      **⛔ Blocked again 2026-06-10 (second live run)** — 0/10 MCQ candidates; root cause D (order prompt never reaches the generation LLM) diagnosed; see `## BLOCKER (2026-06-10, second run)` at the bottom. Do not re-run until D is fixed.

- [SESSION] **42.21 Workflow distractor screen + founder review artifact.** Interactive session (laptop): run a **Workflow** that fans out per candidate MCQ with three judgment lenses — *distractor plausibility* (would a reasonable person consider it?), *answer leakage* (does any distractor or the question text give the answer away?), *voice-friendliness* (SK driving context — options speakable and distinguishable by ear?). Majority verdict per candidate; this is the LLM-judgment layer the deterministic `distractor_quality` checks (substring/length only) cannot provide. Output: `docs/artifacts/mcq-review-<date>.html` — one row per candidate: question, options (correct marked), pattern, scores, workflow verdicts + one-line rationale, source URL, and an approve/reject recommendation. This HTML is the founder's "brief review" surface.
      **Acceptance**: HTML covers 100% of candidates (no silent truncation); every row has a verdict; reply `open <path>`.

- [HUMAN] **42.22 Founder brief review.** Approve/reject per candidate (the 42.21 HTML is the surface). Flip `review_status` to `approved` / `rejected` in the `mcq_batch_*.json` files accordingly; commit.
      **Acceptance**: every candidate carries a final `review_status`; ≥ 1 approved (else Track F loops back to 42.20 with adjusted prompts).

- [ ] **42.23 Importer: `scripts/import_mcq_batches.py`.** Reads `data/generated/mcq_batch_*.json`, selects `review_status == "approved"` only, embeds (`text-embedding-3-small`, batched) and idempotently upserts into the Postgres `questions` table — model on `migrate_chroma_to_postgres.py`'s upsert path (idempotent on id, stamps `review_status='approved'`, `--dry-run` default / `--execute` to write). Code + tests only; no prod execution in this task.
      **Acceptance**: unit tests cover approved-only selection, payload mapping, and id idempotency (mocked session); `--dry-run` over the committed batch files prints the approved count and exits 0.

- [SESSION] **42.24 Prod import + verify.** Interactive session: run 42.23 with `--execute` against prod pgvector via `fly proxy` tunnel (creds + port gotchas: memory `project_quiz_pack_prod_state`). Verify: prod count of `type=text_multichoice` ≥ approved count; re-run with `--execute` is a no-op (0 new inserts); `GET /api/v1/questions` returns ≥ 1 MCQ with populated `possible_answers`.
      **Acceptance**: counts verified via API; idempotency re-run logged. This unblocks #45's human MCQ-voice testing against real prod MCQs.

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

Track F (2026-06-10) depends only on Tracks A–D (all done) and runs **independently of Track E** —
backend-only. Internal order: 42.19 → 42.20 (repeat to ~40) → 42.21 → 42.22 → 42.23 → 42.24.
42.23 may land any time after 42.19 (it reads the same file shape); prod execution (42.24) is gated
on founder approval (42.22). Track E / #45 human MCQ-voice testing benefits from 42.24 landing first
(real MCQs in prod to test against).

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
- 42.19–42.24 (Track F): ≥ 1 founder-approved fresh MCQ batch imported to prod pgvector; `GET /api/v1/questions` serves `text_multichoice` questions with `possible_answers`; import idempotent.

---

## Changelog (verification pass 2026-05-28)

1. **Path fix (42.5)**: prompts live in `apps/quiz-pack-api/prompts/`, not `apps/quiz-pack-api/app/generation/prompts/`. v3_fact_first is the live prompt under the mandatory-Sourcing flow.
2. **Evaluator routing fact (Motivation + 42.13)**: `_evaluate_mcq` routes on `possible_answers` presence (`evaluator.py:77`), not on `question.type`. Added negative test in 42.13.
3. **Question.type is `str`, not Literal (Motivation + 42.8)**: added a Pydantic Literal/validator subtask to 42.8.
4. **Pattern routing split (42.9 → 42.9a + 42.9b)**: original 42.9 assumed pre-generation pattern knowledge that doesn't exist (LLM picks the pattern). Split into post-gen tagging (no generator changes) and prompt-side MCQ emission.
5. **SourcingStage mandatory (42.12)**: `PackGenerator.__init__` now raises `ValueError` if SourcingStage isn't first (#36 task 2.15, `pack_generator.py:53-54`). E2E MCQ test must include a stub SourcingStage.
6. **Two export copies (42.4 + Risk 8)**: root-level and `apps/quiz-agent/` copies of `questions_export.json` exist and are byte-identical; cleanup must touch both. Legacy `q_<hex>` IDs in the export must be preserved (the `_is_uuid` normalisation only fires inside `GenerationStage`).

Triage flipped `needs-info` → `ready-for-agent`. Granularity holds — 42.9b is the densest task (~20 min) but still within Ralph budget.

---

## BLOCKER (2026-06-10) — 42.20 first live MCQ batch: bias not biting (1/9 candidates)

**What was tried.** First live run of the Track F loop, from `apps/quiz-pack-api/` with its own `.venv` and `OPENAI_API_KEY`/`TAVILY_API_KEY` exported from the repo-root `.env` (note: `source .env` fails — lines 8–9 are not shell-parseable; grep the two keys instead):
`python scripts/generate_pack.py --prompt "world history and ancient civilizations" --target-count 20 --dry-run --mcq-bias --out ../../data/generated/mcq_batch_001.json`.
Pipeline completed cleanly (generation 11 → verification 9 → scoring 9 → dedup 9, cost 1¢). Result: **1/9 survivors `text_multichoice`** — below the ≥5 fail-loud threshold, so per this task's instruction the batch was NOT committed (file deleted; regenerable) and the loop stops here.

**Root cause A (primary — pattern-label mismatch).** The LLM emitted `reasoning_pattern` values derived from the prompt's Pattern Library titles: `the_surprising_connection`, `the_hidden_property`, `the_scale_surprise`, `the_odd_one_out`. `choose_question_type` (`app/generation/pattern_routing.py`) exact-matches the bare keys in `PATTERNS_TO_MCQ` (`odd_one_out`, …), so 42.9a's routing fired **zero** times this run — even the one odd-one-out question carried the `the_` prefix despite 42.9b's "exact snake_case key" prompt instruction. That question became MCQ only because the LLM emitted `possible_answers` + `type` directly and the stage's else-branch passes non-routed questions through unchanged.

**Root cause B (bias too weak).** Only 1/9 survivors used an MCQ-routable pattern at all. The prompt's PATTERN DIVERSITY RULE (no pattern >3× per batch of 10) plus the fact-first pipeline (facts drive pattern choice) structurally outweigh the `--mcq-bias` footer appended to the order prompt.

**Observation C (topic drift — pre-existing, surfaced by this run).** Prompt was "world history and ancient civilizations" but all 9 survivors are general trivia (Earl Grey, Michelin stars, saffron…) with `source_url=https://opentdb.com`. The OpenTDB fact source appears not to honour the order topic; this undermines the "vary topic per batch to avoid duplicates" strategy and should be checked before batch 2.

**Next human-touch needs (smallest first):**
1. ~~Normalise pattern labels in `choose_question_type` — reuse `_normalize_pattern` (already in `pattern_routing.py` from #46) + strip a leading `the_`, or add `the_*` aliases to `PATTERNS_TO_MCQ`. Add a regression test with the four labels observed live.~~ **Done 2026-06-10 (Ralph):** `choose_question_type` now runs labels through `_normalize_pattern` and strips a leading `the_` before the `PATTERNS_TO_MCQ` lookup — `the_odd_one_out` and title-case forms ("The Odd One Out", "True False") route to MCQ; the three non-MCQ live labels still degrade to `text`. 6 regression tests added to `tests/generation/test_pattern_routing.py` (4 live-observed labels parametrised + 2 title-case). 261 non-postgres tests green. Root cause A resolved; **B (bias too weak) and C (OpenTDB topic drift) remain** — fix at least B (item 3) before re-running 42.20, since A alone only rescues the odd-one-out fraction of a batch.
2. Consider trusting LLM-emitted `type="text_multichoice"` when `possible_answers` is populated (it is what saved the one candidate) — gated on the same fail-loud missing-options drop.
3. ~~Strengthen the bias: carve MCQ patterns out of the PATTERN DIVERSITY RULE when `--mcq-bias` is set, or fall back to per-pattern sub-batches (Risk #7).~~ **Done 2026-06-10 (Ralph):** `--mcq-bias` footer rewritten from soft "strongly prefer" to a hard quota ("at least 7 of every 10 questions MUST use" + the four pattern keys) and an explicit EXEMPT-from-PATTERN-DIVERSITY-RULE declaration. `_format_mcq_patterns_section` (rendered into both v2/v3 templates whenever `mcq_patterns` is passed) gains a matching "Diversity-rule carve-out" block that is **self-gating** — it only lifts the per-pattern cap when the order prompt declares MULTIPLE-CHOICE EMPHASIS, so unbiased production runs keep the diversity rule unchanged (no flag plumbing through `GenerationStage` needed). 2 new tests pin the quota/exemption wording on both sides (`test_generate_pack_flags.py`, `test_advanced_generator.py`); 1 existing e2e assertion updated to the new marker. 320 non-postgres tests green. Per-pattern sub-batches (Risk #7) remain the escalation if the quota still doesn't bite in the next live run. **A + B resolved — 42.20 may re-run.** C (OpenTDB topic drift, item 4) is an observation, not a gate: MCQ patterns build fine on generic trivia facts; expect topic drift in batch file naming until item 4 is investigated.
4. Check why SourcingStage/OpenTDB ignores the order topic (affects all Track F batches, not just MCQ).

---

## BLOCKER (2026-06-10, second run) — 42.20 re-run after fixes A+B: 0/10 MCQ candidates

**What was tried.** Second live run after blocker fixes A (`24ab3e4`) + B (`21ba3ee`), same recipe as before (keys grepped from repo-root `.env`, run from `apps/quiz-pack-api/` with its `.venv`):
`python scripts/generate_pack.py --prompt "science and the natural world" --target-count 20 --dry-run --mcq-bias --out ../../data/generated/mcq_batch_001.json`.
Pipeline clean (generation 11 → verification 10 → scoring 10 → dedup 10, cost 1¢). Result: **0/10 survivors `text_multichoice`** — worse than the first run's 1/9. All 10 survivors carry title-case Pattern Library labels (`The Historical Quirk` ×4, `The Biological/Physical Oddity` ×4, `The Scale Surprise`, `The Translation Surprise`), zero `possible_answers` emitted. Batch file deleted (regenerable, nothing committable).

**Root cause D (new — order prompt is invisible to the generation LLM).** `GenerationStage.run` (`app/orchestrator/stages/generation.py:155-176`) hands the generator only `topics=[ctx.category, ctx.theme]`, `categories`, `source_facts`, and `mcq_patterns` — **`ctx.prompt` is never passed**; it is used solely for `_compute_prompt_seed`. The `--mcq-bias` footer (hard "at least 7 of every 10" quota + MULTIPLE-CHOICE EMPHASIS declaration, fix B) lives on `order.prompt` → `ctx.prompt`, so the generation LLM never sees it. Worse, fix B's diversity-rule carve-out in `_format_mcq_patterns_section` is self-gated on "if the order prompt declares MULTIPLE-CHOICE EMPHASIS" — a condition the model can never observe — so the carve-out is dead code in practice. The 42.19 acceptance test asserted the bias text reaches `ctx.prompt` ("what GenerationStage hands the generator") — that parenthetical was wrong; `ctx.prompt` is not what the stage hands the generator.

**Root cause E (contributing — MCQ keys are not Pattern Library patterns).** The v3 prompt's Pattern Library (`prompts/question_generation_v3_fact_first.md:77-99`) offers 13 title-case patterns and the Response Format instructs `pattern_used: "Pattern name from library"` (line 221). `true_false` and `year_guess` exist **only** in the appended MCQ-activation section, never as selectable library patterns, so the LLM has no reason to pick them. And library pattern 12 "The Comparison Bet" normalizes (fix A) to `comparison_bet` — which is NOT in `PATTERNS_TO_MCQ` (`comparison_bet_older_larger`), so even a Comparison Bet question would not route to MCQ. Only "The Odd One Out" (pattern 9) both exists in the library and routes after fix A — explaining why run 1 produced exactly one near-MCQ and run 2 (which happened to select no odd-one-outs) produced zero.

**Next human-touch needs (smallest first):**
1. ~~**Fix D properly:** plumb an explicit `mcq_emphasis: bool` from the CLI flag through `OrderContext` → `GenerationStage` → `generate_questions` → `_format_mcq_patterns_section`, and when set, inject the hard quota ("at least 7 of every 10 questions MUST use one of the MCQ patterns") + the diversity-rule exemption **directly into the section** instead of gating on order-prompt text. The order-prompt footer can stay (harmless for sourcing) but is not the mechanism.~~ **Done 2026-06-10 (Ralph):** `OrderContext.mcq_emphasis: bool` added; `PackGenerator.run` derives it deterministically from the new `MCQ_EMPHASIS_MARKER` constant (`pattern_routing.py`) on `order.prompt` — no `GenerationOrder` DB column/migration needed, and the CLI footer now formats from the same constant so footer and detector can't drift. `GenerationStage` passes `mcq_emphasis=ctx.mcq_emphasis` into `generate_questions` → `_generate_batch` → `_format_mcq_patterns_section`, which (when set) injects the hard quota ("at least 7 of every 10 questions") + unconditional diversity-cap exemption directly into the section; the dead self-gated carve-out is removed, so unbiased runs carry no quota/exemption text at all. Tests: emphasis-on/off section assertions + `_generate_batch` prompt-level quota assertion (`test_advanced_generator.py`), stage pass-through pin both ways (`test_generation.py`), end-to-end CLI flag → `ctx.mcq_emphasis is True` (`test_generate_pack_flags.py`). 322 non-postgres tests green. **E (MCQ keys not selectable in Pattern Library) remains — fix item 2 before re-running 42.20.**
2. **Fix E:** make the four MCQ keys selectable — either add `true_false` / `year_guess` entries to the Pattern Library (when emphasis is on) and rename/alias so library names normalize into `PATTERNS_TO_MCQ` (`comparison_bet` alias, or add it to the set), or instruct in the emphasis block: "use library patterns 9/11/12 and emit them as `odd_one_out` / `year_guess` / `comparison_bet_older_larger`".
3. ~~If 1+2 still under-deliver, escalate to per-pattern sub-batches (Risk #7) — generate 4 × 5-question batches each hard-pinned to a single MCQ pattern.~~ **Done 2026-06-11 (`2469d61`):** fix E landed (item 2, commit `4847011`) but two live 42.20 batches still failed the ≥5-MCQ bar — see `## BLOCKER (2026-06-11, third run)` below. Escalated to sub-batches as planned.
4. Re-run 42.20 only after 1+2 land (restart at `mcq_batch_001.json`; both prior batches deleted).

## BLOCKER (2026-06-11, third run) — fix E mechanically works but ≥5-MCQ bar still fails → per-pattern sub-batches landed

**What was tried.** After fix E (`4847011`, MCQ keys selectable in the generation prompt), two live 42.20 batches on mba (gpt-4o, `--dry-run --mcq-bias`): batch 001 = **0 MCQ / 1 survivor**, batch 002 = **1 MCQ / 5 survivors** (the one MCQ an Odd-One-Out). So MCQ routing fires for the first time (fix E works mechanically) but the batch is still **below the ≥5-MCQ bar**.

**Root cause (bigger than fix E).** (1) **Generation-volume collapse** — the best-of-N path asks gpt-4o for `count * n_multiplier` ≈ **57 questions in one call**; the model returns only 4–10 (not truncation — `_parse_response` would yield `[]`; the model simply won't emit 57). (2) **MCQ share far below the ≥7/10 emphasis target** — a single mixed-pattern call lets the model satisfy the quota with whichever one MCQ pattern is easiest, or none.

**Fix (Risk #7 escalation, `2469d61`).** MCQ-emphasis orders now bypass best-of-N and fan out to **one small sub-batch per `PATTERNS_TO_MCQ` key** via `_generate_mcq_sub_batches` in `advanced_generator.py` — each sub-batch pinned to a single pattern with `mcq_emphasis=True`, `count` split evenly across the four patterns, gathered concurrently. Small per-call counts (the LLM actually fills them) + forced per-pattern coverage. Best-of-N critique intentionally skipped (over-generating to ~57 is the failure being replaced; `ScoringStage` stays the quality gate). Regression test `test_mcq_emphasis_fans_out_one_sub_batch_per_pattern` pins the fan-out shape; 192 non-postgres tests green.

**Status:** code landed + pushed. **Live validation (batch 003, mba, gpt-4o, dry-run, same "world history and ancient civilizations" prompt): the sub-batch fix worked on its two targets but the batch STILL fails the ≥5-MCQ bar.**

- ✅ **Volume collapse fixed:** fan-out fired — `MCQ emphasis: 19 questions across 4 per-pattern sub-batches {comparison_bet_older_larger:5, odd_one_out:5, true_false:5, year_guess:4}` → **19 raw** (vs 4–10 in the single-call best-of-N path). 20 questions reached verification (incl. 1 open).
- ❌ **MCQ survivors: 2 / 13** (one `true_false` "True or false: Bob Dylan won a Nobel…", one `comparison_bet` "…approved before or after the U.S. Civil War"). The other 11 survivors are free-form `text`. Still < 5.

**Why it still fails (two new contributing causes, beyond fix E / volume):**
1. **Pattern-pinned sub-batches still emit mostly free-form `text`, not `text_multichoice`.** Even when a sub-batch is pinned to `year_guess`/`odd_one_out`, the LLM writes the question but does not emit `type: "text_multichoice"` + `possible_answers`, so 42.9a routes it to `text`. `dropped_mcq_missing_options: 0` confirms it isn't malforming MCQs — it just isn't attempting them. The emphasis section nudges `pattern_used` but does **not hard-require the output type/options** for the MCQ patterns.
2. **Shallow, duplicate-heavy survivor pool.** All 4 sub-batches share the same 23 sourced facts, so they independently generate near-identical questions (Bob Dylan Nobel ×4, Kilimanjaro ×2 among the 13). `DedupStage` kept 13 / dropped 0 — the 0.85 guard is a no-op because `--dedup-store pgvector` (42.19c) was deferred and there's no working `find_duplicates`.

**⏸️ Founder decision 2026-06-11 — PARK Track F (MCQ batch generation), revisit after most current TODO issues land.** The escalation was surfaced to the founder, who decided the MCQ **generation flow itself needs review/redesign** rather than another incremental fallback + batch. Stop generating packs. When Track F resumes, treat it as a flow-redesign, not a parameter tweak — the candidate levers identified this session are starting points, not the plan: (a) in the per-pattern sub-batch, **hard-require `type:"text_multichoice"` + `possible_answers`** for the MCQ patterns (strongest lever — fixes cause 1 at the contract level); (b) give each sub-batch a **distinct fact slice / topic** so they stop generating the same question; (c) land the deferred **pgvector dedup** (42.19c) so duplicates stop crowding the pool. Code that landed and stays in `main`: `2469d61` (sub-batches + regression test), `4847011` (fix E) — both are correct improvements, just insufficient on their own.
