# Issue 46: Canonical-answer enforcement + dedicated branch for open/logical questions

**Triage:** enhancement · ready-for-agent
**Status:** Plan from a data-driven audit (2026-06-03) of 755 generated questions. All open decisions resolved by the user 2026-06-04 (see Decisions D5–D7). Tasks below are Ralph-ordered and atomic — the whole issue is intended to run in one Ralph loop (Track A backend → Track B backend → Track B iOS). Backend tasks are Ralph-suitable; iOS tasks (46.B7–46.B9) need the simulator and may be `[HUMAN]` depending on the mba SDK gap (see #45).
**Created:** 2026-06-03
**Parent / related:** Continues the intent of #42 (Track B, generation tightening). Independent of #45 (iOS). Touches `quiz-pack-api` generation + verification stages only.

---

## Motivation

User goal: questions should be higher quality and must not produce **unverifiable, long, "logical"** answers (voice-spoken while driving). The working hypothesis was "build a separate workflow for the problematic reasoning/puzzle question types."

I audited the actual data (`scripts/` ad-hoc, 755 questions across `data/generated/*.json` + `apps/quiz-agent/questions_export.json`) to find which questions are actually problematic. **95 answers break the brevity rules (>10 words or carry a `because`/`while`/em-dash tail). Classified by answer SHAPE:**

| Shape | Share | Example (question → answer) |
|---|---|---|
| **Short answer exists, written verbosely** (`other_long` + `tail_bolton`) | **96%** | Sahara 6000y ago → *"A lush green landscape with rivers, lakes"* (should be **"Grassland/savanna"**). GPS → *"Selective Availability — switched off in 2000 by Clinton"* (should be **"Selective Availability"**). |
| **Open "why/how" mechanism** | **2%** (2 q) | "Why are Ferraris red?" → national racing colour explanation. |
| **Lateral-thinking puzzle** (genuinely not web-verifiable) | **2%** (2 q) | "What happens when the Sun goes out?" → reasoning answer. |

**Conclusion that reshapes the task:** 96% of bad answers are **factual questions with a short, verifiable canonical answer that the model wrote as a descriptive sentence**. They do **not** need a new workflow — they need the existing factual pipeline to *enforce a short canonical answer* and push detail into `explanation`. The genuinely "different kind" (open mechanism + lateral puzzles) is only ~4%, but the user wants to keep those types **and** stop them producing long/unverifiable answers — so a dedicated branch is justified as a forward-looking guardrail, not as the main fix.

### Two axes, not one

The real model has two independent axes:

- **Answer shape:** *closed* (short canonical: name/number/year/winner/true-false) vs *open* (mechanism/cause/puzzle resolution — inherently a sentence).
- **Verification mode:** *external-factual* (web source agreement, today's `FactVerifier`) vs *internal-logical* (does the answer uniquely follow from the setup — no web source exists).

96% of the pain is the **answer-shape** axis (open answers that should be closed). The original "unverifiable" worry is the **verification-mode** axis, which affects only the rare lateral-puzzle tail. Both are addressed below, but Track A (shape) is the high-value work.

### Pipeline gaps that allow this

- **The v3 prompt tells the model to "move context into `explanation`" but the response-format JSON has no `explanation` field** (`apps/quiz-pack-api/prompts/question_generation_v3_fact_first.md:194` instruction vs the response schema at `:216-250` — no `explanation` key). So there is nowhere for the discarded context to land; the model keeps it in `correct_answer`. Same gap in `question_generation_v2_cot.md`.
- The post-generation validator (`apps/quiz-pack-api/app/orchestrator/stages/generation.py:36-56`, `:128-146`) **drops** verbose answers but never **repairs** them — a question with a perfectly good short answer buried in a sentence is thrown away instead of normalized.
- `FactVerifier` (`app/verification/fact_verifier.py`) is the only verifier; `VerificationStage` (`app/orchestrator/stages/verification.py:45-96`) runs every question through it and drops `confidence < 0.5` (`:28`, `:86`). A lateral puzzle has no web source → low confidence → silent drop (wasted tokens) **or** a tangential source gives spurious confidence → bad puzzle ships.
- F8 (`generation.py:184-197`) hard-requires `source_url` on every question. Invented lateral puzzles have no URL → `raise ValueError`. This is likely why almost no puzzles exist in the data.
- Gold-standard examples injected into the prompt (`data/examples/gold_standard.json`) still contain verbose answers (per #42 notes), so the model learns the long form is acceptable.

---

## Decisions

- **D1 (delegated to me, resolved from data) — what routes to the new "open/logical" branch:** route by **question shape**, not by pattern number. A question goes to the open branch iff its answer cannot be reduced to ≤5 words *because the question asks for a mechanism, cause, or puzzle resolution* — i.e. open "why/how/what-would-happen" framings and explicit lateral-thinking puzzles. **Everything else stays factual**, including Estimation (11), Comparison Bet (12), Reverse Engineer (13), Odd-One-Out, True/False, Number Sequence, Analogy — their answers are short and stay short (Track A enforces it). Rationale: the data shows 96% of "logical-looking" long answers are actually closed-answer questions written verbosely; only true open/puzzle shapes need different handling.
- **D2 — verification dispatch:** `VerificationStage` becomes a dispatcher keyed on the branch. Factual branch → `FactVerifier` (unchanged). Open branch: factual-mechanism answers → still `FactVerifier` on the explanation text (these *are* web-verifiable, e.g. TRPV1, entropy); pure lateral puzzles → new `LogicalConsistencyVerifier` (LLM judge, no web): does the answer uniquely follow from the setup, can a reasonable player deduce it, what alternative answers must be accepted (→ populate `alternative_answers`), is the setup self-contained.
- **D3 — no category lost.** Every existing pattern still gets generated. The split changes *how a question is generated and verified*, never *whether* a type can exist.
- **D4 — F8 relaxation scoped to the open branch only.** Lateral puzzles may persist with `source_url = null` and a provenance marker (`pipeline = "logical_puzzle"`, verified by consistency). Factual branch keeps the hard F8 requirement.
- **D5 (user 2026-06-04) — F8:** relax `source_url` for the logical branch **now** so puzzles can ship, but ideally puzzles should still carry *some* source/reference. **Populating a reference URL for puzzles is deferred to a follow-up TODO**, not done in this issue.
- **D6 (user 2026-06-04) — sequencing:** Track A first, then Track B, **all in one Ralph loop**. Tasks below are ordered so the loop runs A→B end to end.
- **D7 (user 2026-06-04) — open-branch answer fields:** use **two distinct properties** — a new `headline_answer` (short, gettable gist, scored by the evaluator) and the existing `explanation` (full context, read aloud after). This is an **API-contract change**: it touches `packages/shared`, the evaluator + Evaluation response, **and** iOS (`Question.swift`, `Evaluation.swift`, `ResultView.swift`). Run `/verify-api` after the model change.

---

## Scope

**In:**

- **Track A — canonical-answer enforcement (factual branch, covers ~96%):**
  - A1. Add an `explanation` field to the v2_cot + v3 response-format JSON and require the model to emit `correct_answer` (≤5 words) **and** `explanation` (the context) as separate fields.
  - A2. Replace the drop-only validator in `GenerationStage` with a **normalize-then-drop** step: if `correct_answer` has a clean short head before a tail marker (`—`/`because`/`while`/`,`), split head→`correct_answer`, tail→`explanation`; only drop if no short head exists. Deterministic regex first, LLM normalization fallback for the ambiguous remainder (per CLAUDE.md rule #5: LLM only for the judgment call of "what is the canonical answer").
  - A3. Clean verbose answers out of `data/examples/gold_standard.json` so the prompt stops teaching the long form.
  - A4. One-off normalization pass over existing data (`data/generated/*.json` + prod export) reusing A2's splitter; report counts, fail-loud on anything unsplittable.
- **Track B — open/logical branch (covers ~4%, forward-looking):** routing, dedicated prompt, `LogicalConsistencyVerifier`, dispatcher, **plus the new `headline_answer` field end to end (backend + iOS, D7).**

**Out (non-goals):**

- Whole-prompt redesign — Track A/B are additive (new fields, new branch), not a rewrite.
- New scoring dimensions — `answer_brevity` (#42) already covers it; the open branch is exempted from the >10-word penalty via `answer_shape`.
- New categories / batches (#30 owns that). ChromaDB (#41).
- **Populating a reference/source URL for logical puzzles** — deferred per D5 (tracked as a separate TODO).

---

## Tasks (Ralph-ordered — one loop, A→B)

> Each task is atomic and self-verifying. Backend tests: `cd apps/quiz-pack-api && pytest tests/ -v`. iOS: build + unit/inspector tests per `.claude/rules/ios.md`.

**Track A — canonical-answer enforcement (factual branch, ~96% of the win):**

- **46.A1** Add `explanation` to the response-format JSON in `prompts/question_generation_v3_fact_first.md` (schema at `:216-250`) and `question_generation_v2_cot.md`; require `correct_answer` (≤5 words) and `explanation` (context) as separate fields. *Verify:* prompt snapshot test asserts both keys present.
- **46.A2** Replace the drop-only validator in `GenerationStage` (`app/orchestrator/stages/generation.py:36-56,128-146`) with **normalize-then-drop**: split a clean short head before a tail marker (`—`/`because`/`while`/`,`) into `correct_answer`, move the tail to `explanation`; drop only when no short head exists. Deterministic regex first; LLM normalization fallback for the ambiguous remainder (CLAUDE.md rule #5). *Verify:* unit tests for split/keep/drop cases incl. the audit examples (Sahara, GPS, Toy Story).
- **46.A3** Strip verbose answers out of `data/examples/gold_standard.json` (move context to each example's `explanation`). *Verify:* assertion that no `correct_answer` in the file exceeds the word cap.
- **46.A4** One-off normalization pass over `data/generated/*.json` + `apps/quiz-agent/questions_export.json` reusing 46.A2's splitter; emit a report of split/kept/dropped counts; fail-loud on unsplittable. *Verify:* re-run the audit script → 0 over-cap answers with a recoverable short head.

**Track B — open/logical branch + `headline_answer` (~4%, forward-looking):**

- **46.B1** Extend `app/generation/pattern_routing.py` with `answer_shape(pattern, question_text) -> "closed"|"open"` and `verification_mode(pattern, question_text) -> "factual"|"logical"`, both fail-safe to `closed`/`factual`. *Verify:* unit tests incl. "why/how" + lateral-puzzle inputs.
- **46.B2** Add `headline_answer: Optional[str]` to `packages/shared/quiz_shared/models/question.py` (+ `from_dict`); add to the Evaluation response model the evaluator returns. *Verify:* `pytest packages/shared`; `curl /openapi.json` shows the field. Run `/verify-api`.
- **46.B3** New prompt `prompts/question_generation_open.md` — open-shape questions emit a short `headline_answer` (≤8 words) **plus** full `explanation` **plus** listed `alternative_answers`; the sentence-answer exception lives **only here**. *Verify:* prompt snapshot test.
- **46.B4** Route open-shape generation through 46.B3 in `GenerationStage` (split `target_count` by `answer_shape`, or post-route); set `pipeline = "logical_puzzle"` on pure puzzles. Relax F8 (`generation.py:184-197`) to skip `source_url` only when `pipeline == "logical_puzzle"` (D4/D5). *Verify:* e2e test that a puzzle persists with `source_url = null` and a factual question still fails F8 without a URL.
- **46.B5** New `app/verification/logical_verifier.py` — `LogicalConsistencyVerifier` (LLM judge, no web) returning the same verdict/confidence shape as `FactVerifier`; checks uniqueness, deducibility, alternative answers (→ populate `alternative_answers`), self-contained setup. *Verify:* unit test with a mocked LLM for verified/uncertain verdicts.
- **46.B6** Make `VerificationStage` (`app/orchestrator/stages/verification.py:45-96`) a dispatcher (D2): `verification_mode == "logical"` → `LogicalConsistencyVerifier`; else `FactVerifier`. Default to `FactVerifier` on any uncertainty (R2). *Verify:* unit test asserting routing by mode.
- **46.B7** Evaluator: for questions with `headline_answer`, score the spoken answer against it (generous match) and return it in the result (`apps/quiz-agent/app/evaluation/evaluator.py:63-83`). *Verify:* evaluator unit test.
- **46.B8** iOS Codable: add `headlineAnswer` to `apps/ios-app/Hangs/Hangs/Models/Question.swift` (CodingKeys `:49-61`, decode `:75-87`, init `:110-131`) and `Evaluation.swift` (`:15-25`). *Verify:* iOS build + decode unit test against a fixture.
- **46.B9** iOS render: show `headlineAnswer` as the revealed answer and `explanation` as the follow-up in `apps/ios-app/Hangs/Hangs/Views/ResultView.swift`. *Verify:* snapshot test for an open-branch question reveal.

---

## Risks

- **R1 — LLM normalization (A2) changes meaning.** Splitting "X — because Y" can pick the wrong head. Mitigate: deterministic split first, LLM only on the ambiguous remainder, and keep `explanation` so nothing is lost; spot-check the A4 batch run.
- **R2 — dispatcher misroutes (B1).** A factual question tagged "open" would skip web verification. Mitigate: default to `factual`/`FactVerifier` on any uncertainty (fail-safe, mirrors `choose_question_type`'s existing fail-safe to `text`).
- **R3 — relaxed F8 (D4) lets unsourced factual questions slip through** if the branch tag is wrong. Mitigate: relaxation keyed strictly on `pipeline == "logical_puzzle"`, set only by the open-branch generator, never by the factual path.
- **R4 — scope creep back into a prompt rewrite.** Hold the line: A1/B2 add fields and one new prompt; they do not restructure the existing prompt bodies.
