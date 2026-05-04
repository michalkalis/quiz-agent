# Issue 29: Backfill `source_url` / `source_excerpt` on existing questions

**Triage:** enhancement · done
**Status:** Done
**Created:** 2026-05-02
**Closed:** 2026-05-04
**Surfaced by:** Split of #21 (Groups B-E). This is **Group D1** of `question-pipeline-remaining.md`.

## TL;DR

The 2026-04-01 snapshot showed 69 questions in export / 89 in ChromaDB with verification results: 55 correct, 8 needs_fix, 2 incorrect, 4 needs_review. None have `source_url` / `source_excerpt`. `scripts/backfill_sources.py` exists (5127 B, last touched Mar 18) but has not been run end-to-end.

Fact-check the existing corpus, populate source fields, flag questions that don't survive verification.

## What to implement

1. **Re-count first.** The 2026-04-01 numbers are stale. Run a quick `check_db_status.py` (or equivalent) and record current counts in the PR description, not in the issue file.

2. **Bring the script forward.** Audit `scripts/backfill_sources.py`:
   - Confirm it talks to the question-generator on `:8003` (`POST /api/v1/verify/batch`) and not a removed endpoint.
   - Confirm it writes back into ChromaDB via `QuestionStore.upsert` (not the old direct `ChromaDBClient.update_question` — that was a silent no-op fixed in #22, see memory `project_chroma_update_bug`).
   - Add a `--dry-run` mode if missing.

3. **Run the backfill** against the local DB:
   - Start question-generator (`:8003`) and quiz-agent (`:8002`).
   - Execute the script, capture the per-question outcome.
   - For `needs_fix` / `incorrect`: write the verifier's suggested fix into a review file, do NOT auto-apply.

4. **Promote to prod.** Once the local snapshot is healthy, sync to Fly.io ChromaDB. Memory `project_prod_chroma_mount` covers the volume layout. Confirm `CHROMA_PATH` matches before any write.

## Where the work lands

| Where | What changes |
|---|---|
| `scripts/backfill_sources.py` | Adapt to current API + `QuestionStore.upsert`; add `--dry-run` |
| `data/chroma/` (local) | Updated metadata: `source_url`, `source_excerpt`, `verified_at` |
| `data/questions/<batch>-needs-fix.md` (new) | Hand-written review file for the flagged questions |
| Production volume | After local sign-off only |

## Acceptance

- Every question that verifies `correct` carries `source_url` + `source_excerpt`.
- Flagged questions are listed in a review file with the verifier's reasoning, not deleted.
- Re-running the script is idempotent (already-verified questions skip).
- Memory `project_question_quality` updated with new snapshot (counts + verification breakdown + date).

## Caveats

- **Don't auto-fix `needs_fix` / `incorrect`.** Question quality is the user's top concern (memory `feedback_root_cause_debugging`); silent edits hide problems. Surface them for human review.
- **Avoid hitting prod first.** Verify locally; only sync once the diff is reviewed.
- **Tavily costs money.** ~$0.003 per question; budget check before running on 89.
- **`generated_by` may be missing** on the legacy 69 — that's expected; the backfill should not set it.

## Related

- #21 (umbrella, superseded) — this issue carries Group D1.
- #28 — Adds `age_appropriate` (separate concern; do not bundle).
- #30 — New batch content (Group E); should run *after* this so we don't fact-check brand-new questions a second time.
- Memory `project_chroma_update_bug` — historical no-op now fixed via `QuestionStore.upsert`.
- Memory `project_prod_chroma_mount` — production volume layout.

## Outcome (2026-05-04)

Two-phase landing.

**Phase 1 — backfill script + bulk source push (commit 58a4253):**
- `scripts/backfill_sources.py` updated: multi-file input, last-writer-wins
  merge, idempotent on re-run.
- Local ChromaDB: 67/67 approved questions carry `source_url` (100%); 134
  pending also sourced.
- 8 approved + 1 pending questions flagged needs_fix/needs_review by the
  verifier — surfaced to `data/questions/backfill-needs-fix.md` per the
  "no auto-fix" rule, awaiting human decision.

**Phase 2 — human-reviewed corrections + prod sync (this commit):**
- `data/verification/corrections_2026-05-04.json` — 8 field-level diffs
  applied per verifier suggestions:
  - 7 in-rotation: rephrased to remove false claims (legal ban → guidelines,
    debunked myths reframed as "legendarily said to", etc.)
  - 1 pending (`q_tech_002`): answer "Bill Gates" → "Bill Gates and Paul
    Allen", flipped to `approved`.
  - 1 (`q_img_hint_image_003` Moon Landing painting): kept as-is — flagged
    only because Gemini was unavailable; per user, no Gemini soon.
- `scripts/apply_question_corrections.py` — applies field-level patches
  locally via `QuestionStore.upsert`, then to prod via DELETE + IMPORT +
  backfill-sources. Rate-limit-aware (admin endpoints are 5/min capped).
- `scripts/push_sources_to_prod.py` — extended to accept multiple files,
  merges to one POST.
- Prod sync: 8 corrections deleted+reimported with sources backfilled;
  bulk push covered 49 newly-updated source attributions across the
  remaining corpus. Total prod questions unchanged at 300.

Acceptance criteria met:
- All approved questions in prod carry `source_url` + `source_excerpt`.
- Flagged questions are recorded in `backfill-needs-fix.md` with the
  verifier's reasoning; corrections are tracked in `corrections_*.json`.
- Backfill + correction scripts are idempotent (last-writer-wins).
