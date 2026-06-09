# Issue 50: MCQ activation — backend retriever cutover

**Triage:** enhancement · ready-for-agent
**Status:** Created 2026-06-09 from launch decision "MCQ in launch" (`docs/product/launch-decisions-2026-06-08.md`). Backend slice only — Ralph-able, pure Python, no DB required for tests. Numbering note: #49 stays reserved for the pre-release gauntlet remediation referenced from `issue-48`.
**Created:** 2026-06-09
**Related:** `issue-42-question-quality-and-mcq.md` (built the MCQ pipeline), `issue-45-ios-mcq-voice-and-redesign.md` (iOS surface), `docs/handoffs/handoff-2026-06-09-1042.md` (names this as next launch work)

## TL;DR

All MCQ plumbing from #42 is live — generation tags `text_multichoice`, the evaluator fast-path routes on `possible_answers` presence (`app/evaluation/evaluator.py:83`, regression-tested in `tests/test_mcq_evaluator.py`), and `question_to_dict` already serializes `possible_answers`. The **one remaining backend gate** is the voice-quiz retriever: `QuestionRetriever` hardcodes `["text", "image"]` in **four places** (`apps/quiz-agent/app/retrieval/question_retriever.py` lines 212, 289, 310, 330 — primary filter + all three fallbacks), so MCQ questions can never be served. This issue consolidates that list into one constant and adds `text_multichoice`.

**Safety:** every filter also requires `review_status == "approved"`. Until the converted MCQ batch is human-approved (HUMAN follow-up below), this change serves nothing new — activation is content-gated, not code-gated, after this lands.

## Tasks (Ralph: one per iteration, top to bottom)

- [x] **50.1 Consolidate the four hardcoded type lists into one constant.** In `apps/quiz-agent/app/retrieval/question_retriever.py`, replace the four literal `["text", "image"]` occurrences (lines 212, 289, 310, 330) with a single module-level `ALLOWED_QUESTION_TYPES` constant (keep value `["text", "image"]` — **no behavior change in this task**). Add `apps/quiz-agent/tests/test_question_retriever_filters.py` proving single-source-of-truth: monkeypatch the constant and assert (a) `_build_metadata_filters` reflects the patched list, and (b) each of the three fallback `self._store.search` calls passes the patched list — use a stub store that records `filters` per call and returns no candidates so the fallback chain runs to the end. *Why it matters:* the launch cutover must not miss a fallback path; a stale literal would silently serve MCQ only on the happy path.
      **Acceptance:** new tests pass; `cd apps/quiz-agent && python -m pytest tests/ -q` fully green (98 existing tests stay green).

- [x] **50.2 Add `"text_multichoice"` to `ALLOWED_QUESTION_TYPES`.** One-line value change plus a comment pointing at `docs/product/launch-decisions-2026-06-08.md` (MCQ in launch). Extend `test_question_retriever_filters.py`: without any patching, the primary filter and all three fallback filters must include `"text_multichoice"` in `type.$in`. *Why it matters:* this is the actual activation; the test pins the launch contract so a future "tidy-up" can't silently de-activate MCQ.
      **Acceptance:** tests assert `"text_multichoice"` present in all four filter paths; full suite green.

- [ ] **50.3 pgvector round-trip regression test for MCQ (DB-free).** New `apps/quiz-agent/tests/test_pgvector_mcq_roundtrip.py` exercising the pure helpers `_question_to_row_dict` / `_row_to_question` in `packages/shared/quiz_shared/database/pgvector_client.py` (importable via the existing pytest `pythonpath`; a plain dict works as the row). Build a `Question` with `type="text_multichoice"`, `possible_answers={"a": ..., "b": ..., "c": ..., "d": ...}`, `correct_answer="b"`; assert all three fields survive the round trip exactly. *Why it matters:* the evaluator fast-path fires on `possible_answers` presence — if the store drops it, an MCQ silently downgrades to LLM free-text evaluation and the iOS picker gets no options. No live Postgres needed (do NOT touch `apps/quiz-pack-api/tests/db/` — those need a DB service).
      **Acceptance:** test passes; full quiz-agent suite green.

- [ ] **50.4 Serializer contract test for MCQ.** New `apps/quiz-agent/tests/test_serializers_mcq.py` for `app/serializers.py::question_to_dict` with an MCQ question: assert the dict contains `type == "text_multichoice"` and the full `possible_answers` dict, and **does not** contain `correct_answer` (the docstring promise — the client must never see the answer key, MCQ makes a leak instantly exploitable). *Why it matters:* iOS routes to `MCQOptionPicker` on `type` + options; this is the API contract #45's human tasks build on.
      **Acceptance:** test passes; full suite green.

## Out of scope (do NOT do in this issue)

- **No iOS changes** — #45 tasks 45.7–45.13 are `[HUMAN]` on the laptop.
- **No content approval** — approving the converted MCQ batch is a founder review step.
- **No translation work** — note for the record: `question_to_dict_translated` translates only the question text, not `possible_answers`, so SK/CZ sessions will see English options until that's decided. Flagged as an open product question below; do not "fix" it here.
- **No quiz-pack-api changes** — generation side shipped in #42.

## HUMAN follow-ups (after this lands)

1. Approve the converted MCQ batch (review tool) — until then the retriever change is dormant by design.
2. iOS #45.7–45.13 on the laptop (simulator + design file).
3. Product decision: translate `possible_answers` for SK/CZ, or launch MCQ EN-only? (`question_to_dict_translated` currently leaves options untranslated.)

## Success criteria

- `QuestionRetriever` has exactly one source of truth for allowed types and it includes `text_multichoice`.
- Filter behavior pinned by tests on the primary path and all three fallbacks.
- MCQ fields proven to survive pgvector row round-trip and API serialization, with `correct_answer` proven absent from the client payload.
- Full backend suite green (`98 + new` tests, 0 skipped).
