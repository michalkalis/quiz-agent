# Issue 30: Batch-generate questions for new categories

**Triage:** enhancement · ready-for-agent
**Status:** Open (top-up phase — disney/football below target; doc drift cleanup required)
**Created:** 2026-05-02
**Surfaced by:** Split of #21 (Groups B-E). This is **Group E** of `question-pipeline-remaining.md`. Now unblocked by #27 (PendingStore) and Group A skills.

## TL;DR

Run the gen → verify → score → approve → import pipeline at volume to fill the new categories with quality content. Targets:

| Category | Type | Target count |
|---|---|---|
| `kids` | core | 50 — DONE (52, 2026-05-05) |
| `general` | core | 50 — DONE (53 in batch MDs, 52 approved to local ChromaDB 2026-05-19; 2 flagged as ≥0.85-similarity duplicates: `gen032_q24` honey-in-Egyptian-tombs, `gen033_q06` Venus-day-longer-than-year); prod sync pending |
| `adults` | core | 50 — DONE (67) |
| `wizarding-world` | themed | 30 — DONE |
| `superheroes` | themed | 30 — 34/30 DONE (8 approved LOCALLY 2026-05-19; prod sync pending) |
| `disney` | themed | 30 — 20/30 |
| `football` | themed | 30 — 22/30 |
| `sports-mix` | themed | 30 — 30/30 DONE (20 approved LOCALLY 2026-05-19; prod sync pending) |

## What to do

For each category, loop the skill chain in batches of ~20:

```
/gen-questions --category <cat> --count 20
/verify-qs
/score-qs
# review the score-qs output, then approve only what passes
```

Approved questions land in `PendingStore` (#27) → promoted to ChromaDB on `/questions/approve`.

Per-batch acceptance bar (mirrors `/score-questions`):

- Verify: status `correct` (no `needs_fix` / `incorrect` / `needs_review` allowed in the approved set).
- Score: pass on the 5 engagement dimensions — Conversation Spark, Surprise/Delight, Tellability, Driving Friendliness, Clever Framing.
- Reject is fine; the goal is the target count of *approved*, not generated.

## Where the work lands

| Where | What changes |
|---|---|
| `data/questions/batch-NN-<category>.md` | One file per batch with raw output, verify results, score notes |
| ChromaDB (local then prod) | Approved questions promoted via `PendingStore` → ChromaDB |
| Memory `project_question_quality` | Update with running counts after each category clears |

## Acceptance

- All eight categories meet their targets.
- Every approved question has `source_url` + `source_excerpt` (verifier output, not blank).
- Every approved question has a `generated_by` tag in `generation_metadata`.
- After deploy, iOS picker (#28) returns content for each new category.

## Sequencing & dependencies

- **Do #28 first** so iOS can actually request the new categories.
- **Do #29 first** so the existing 69 are clean before we add new content (avoids re-verifying old + new in one pass).
- Then run #30 category-by-category. Themed categories (wizarding-world, etc.) are independent and can be parallelized in separate sessions.

## Caveats

- **Tavily + LLM cost adds up.** ~$0.004/q verified + generation tokens. Budget per batch and stop early if cost runs hot.
- **Don't bypass the score gate.** Quality > volume (memory `project_question_quality`).
- **Themed categories cannibalize each other.** Wizarding-world and Disney overlap on franchise IP; check for duplicates with `QuestionRetriever` semantic search before approve.
- **`age_appropriate` must be set** by the prompt (default `all`); kids batches must be `8+` or stricter (#28 covers the model field).
- **Stop and revisit Group C/D2/D3** once batches accumulate ≥50 user ratings (see deferred-issue note in `question-pipeline-remaining.md`).

## Related

- #21 (umbrella, superseded) — this issue carries Group E.
- #27 — PendingStore lands the import flow this depends on.
- #28 — Adds the categories iOS will request.
- #29 — Cleans existing questions first.
- Skills: `/gen-questions`, `/verify-qs`, `/score-qs` (all Group A, done 2026-04-15).
- Memory `project_question_quality` — quality bar + pipeline overview.

---

## Tasks — Top-Up Run (2026-06-09)

Six of eight categories are at or above target. Disney and football remain below target and need a top-up run.

- [ ] **30.1** Generate a new batch of 20 disney questions (`/generate-questions --category disney --count 20`), verify all with `/verify-questions`, score passing ones with `/score-questions`, and approve those that clear the 5-dimension bar. Commit the batch file. Acceptance: at least 5 new questions reach `approved` status in the local question store; batch file saved to `data/questions/`.
- [ ] **30.2** Generate a second disney batch of 20 if the first batch yielded fewer than 10 approved (i.e., disney is still below 30 total). Same verify → score → approve cycle. Commit. Acceptance: disney approved count ≥ 30 OR a BLOCKER note explains why 30 is unreachable from available IP-safe questions.
- [ ] **30.3** Generate a new batch of 20 football questions (`/generate-questions --category football --count 20`), verify all with `/verify-questions`, score passing ones with `/score-questions`, and approve those that clear the bar. Commit the batch file. Acceptance: at least 5 new questions reach `approved` status; batch file saved.
- [ ] **30.4** Generate a second football batch of 20 if the first batch yielded fewer than 8 approved (i.e., football is still below 30 total). Same cycle. Commit. Acceptance: football approved count ≥ 30 OR a BLOCKER note explains why.
- [ ] **30.5** Run `migrate_chroma_to_postgres.py --execute` (from `apps/quiz-pack-api/`) to push the newly approved disney and football questions to the prod pgvector store. Acceptance: script exits 0 and reports a net-positive count increase; verify by querying prod API `GET /api/v1/questions?category=disney` and `GET /api/v1/questions?category=football` and confirming counts rose above 20 and 22 respectively.
- [ ] **30.6** Update this issue file: change **Status** to `Done`, update the disney and football rows in the TL;DR table to reflect final approved counts, and reconcile the dangling `#62` reference in `docs/todo/TODO.md` (either inline the note removing the `#62` reference, or create a minimal `docs/issues/issue-62-disney-football-topup.md` stub pointing here). Commit. Acceptance: the file no longer references an open `#62` that doesn't exist; issue-30 header shows Done.

---

## Agent Brief — 2026-06-09

> *This was generated by AI during triage.*

**Category:** enhancement
**Summary:** Top up disney and football question counts to 30/30 via the existing gen→verify→score→approve→migrate pipeline, then close out the issue and its dangling #62 reference.

**Current behavior:**
The full batch pipeline was executed in late May 2026. Six of eight categories (kids, general, adults, wizarding-world, superheroes, sports-mix) met or exceeded their targets. Disney reached 20/30 and football reached 22/30. The production pgvector store was synced on 2026-06-09 with all then-approved questions (308 total). No further batches have been generated for disney or football since that sync. The TODO.md entry for #30 was marked `[x]` done but referenced a `#62` issue that has no file — this is a dangling reference.

**Desired behavior:**
Disney and football each have ≥ 30 approved questions in the prod pgvector store. The issue is marked Done. The `#62` reference is resolved (either as an inline note in TODO.md, or as a created stub issue). The INDEX.md row for #30 reflects `enhancement · done`.

**Key interfaces / call paths:**
- `/generate-questions` skill — generates raw question batches for a named category; persists batch file to `data/questions/batch-NN-<category>.md`
- `/verify-questions` skill — runs Tavily-backed factual verification; sets `verify_status` on each question
- `/score-questions` skill — scores on 5 engagement dimensions; produces approve/revise/reject recommendation
- `PendingStore` (issue #27) — questions approved via `/questions/approve` endpoint land here before ChromaDB promotion
- `migrate_chroma_to_postgres.py` in `apps/quiz-pack-api/` — the migration script that pushes approved ChromaDB content to the prod pgvector store (run from `apps/quiz-pack-api/` cwd with `--approved-only` filter and `--execute` flag to make it non-dry-run)
- Prod pgvector store — queried via `GET /api/v1/questions?category=<cat>` to confirm count

**Acceptance criteria:**
- [ ] `GET /api/v1/questions?category=disney` returns ≥ 30 questions from prod
- [ ] `GET /api/v1/questions?category=football` returns ≥ 30 questions from prod
- [ ] Every newly approved question has non-empty `source_url` and `source_excerpt` fields
- [ ] The issue-30 file header shows **Status:** Done
- [ ] No dangling `#62` reference remains in `docs/todo/TODO.md` pointing to a non-existent file

**Out of scope:**
- Re-verifying or re-scoring already-approved questions in any other category
- Adding categories beyond the eight defined in this issue
- Changing the scoring dimensions or approval thresholds
- Any iOS or backend API changes

**Suggested feedback loop:**
After each batch generation and approval cycle, query the local question store count by category. After the migration step, verify prod via `curl https://<prod-host>/api/v1/questions?category=disney` and confirm count ≥ 30. Tasks 30.1–30.4 are self-contained batch units; 30.5 is the single migration gate; 30.6 is the doc cleanup close-out.

---

## Needs from founder — 2026-06-09

> *This was generated by AI during triage.*

1. **Is disney/football reaching 30/30 a hard requirement before App Store submission?**

   **ANSWERED 2026-06-09 — NO.** Founder: *"we don't need more of specific categories, we rather need
   more general questions."* Disney/football top-up is **not a launch requirement** and is dropped (not
   merely deferred). Tasks 30.1–30.5 (disney/football batches + migrate) are **won't-do**; only the
   doc-cleanup task 30.6 (resolve the dangling `#62` reference) still applies.

   **New direction — generate more GENERAL-category questions.** `launch-issue30.sh` as written targets
   disney/football and is now the wrong target; it must be **repurposed to the `general` core category**
   (or a fresh issue opened) with a founder-set volume target before any Ralph run. Open question back to
   founder: target count for `general` (currently ~52 approved; raise to what — e.g. 100?), and whether
   `kids`/`adults` core categories should grow too.
