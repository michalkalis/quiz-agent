# Issue 30: Batch-generate questions for new categories

**Triage:** enhancement · ready-for-agent
**Status:** Open — growing `general` → ~500 incrementally (tasks 30.G/30.M/30.done/30.docfix active; founder decision 2026-06-09). Disney/football top-up dropped 2026-06-09 (not a launch requirement).
**Created:** 2026-05-02
**Surfaced by:** Split of #21 (Groups B-E). This is **Group E** of `question-pipeline-remaining.md`. Now unblocked by #27 (PendingStore) and Group A skills.

## TL;DR

Run the gen → verify → score → approve → import pipeline at volume to fill the new categories with quality content. Targets:

| Category | Type | Target count |
|---|---|---|
| `kids` | core | 50 — DONE (52, 2026-05-05) |
| `general` | core | **500** — ~207 approved (52 original + 16 from batch-04 2026-06-11 + 19 from batch-05 2026-06-11 + 20 from batch-06 2026-06-11 + 20 from batch-07 2026-06-11 + 20 from batch-08 2026-06-11 + 20 from batch-09 2026-06-12 + 20 from batch-10 2026-06-12 + 20 from batch-11 2026-06-12); **raised to ~500 by founder 2026-06-09, approached incrementally** (see "General content run" below) |
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

## Tasks — General content run toward 500 (2026-06-09)

**Founder decision 2026-06-09:** disney/football top-up is **dropped** (not a launch req). The new
direction is **more `general`-category questions**, target **~500**, **approached slowly** — many
short, committed runs over time, not one giant batch. This is a **re-runnable** loop: each Ralph run
(or session) advances the count by a few batches and stops; re-launch later to advance further.

**Per-run protocol** (repeat 30.G each iteration until the run's iteration budget is spent):

- [ ] **30.G** *(repeatable — the core loop)* Generate one batch of 20 `general` questions
  (`/generate-questions 20 --category general` — count is positional per the skill's argument-hint), verify all with `/verify-questions`, score
  passing ones with `/score-questions`, and approve only those that clear the 5-dimension bar. Commit
  the batch file to `data/questions/`. **Before generating, check the running `general` approved count**
  — if it is already ≥ 500, do **not** generate; skip to 30.M then 30.done. **Dedup guard:** run a
  `QuestionRetriever` semantic check and drop any new question ≥ 0.85 similarity to an existing
  `general` question (the two known dupes — `gen032_q24`, `gen033_q06` — are the precedent). Acceptance
  per iteration: ≥ 1 new `general` question reaches `approved`; batch file committed; the running count
  in the TL;DR `general` row is updated.
- [ ] **30.M** *(end of each run, or every ~5 batches)* Run `migrate_chroma_to_postgres.py --execute`
  (from `apps/quiz-pack-api/`) to push newly-approved `general` questions to prod pgvector. Acceptance:
  script exits 0 with a net-positive count increase; `GET /api/v1/questions?category=general` count rose.
- [ ] **30.done** *(only when `general` approved ≥ ~500)* Set **Status** to `Done`, update the `general`
  row to the final count. Until then the issue stays open across runs.
- [x] **30.docfix** *(done 2026-06-11)* Reconcile the dangling `#62` reference in
  `docs/todo/TODO.md` (inline a note removing it, or create a minimal stub pointing here). Acceptance:
  no open `#62` reference remains pointing to a non-existent file.

> **Why count-based, not a fixed task list:** ~450 questions ≈ 23+ batches at a healthy approval rate —
> too many to enumerate, and the founder wants this paced. The loop's success criterion is the *count*,
> not a checkbox per batch. Each run is bounded by `MAX_ITERS` in `launch-issue30.sh`; raise it for a
> bigger push, lower it to go slower.

---

## Agent Brief — 2026-06-09

> *This was generated by AI during triage.*

> **⚠ Superseded 2026-06-09 — read the "General content run" task section above, not the disney/football
> wording below.** Founder dropped the disney/football top-up; the goal is now `general` → ~500,
> incremental. The pipeline/interfaces below still apply (just point them at `general`).

**Category:** enhancement
**Summary:** Grow the `general` core category from ~52 toward ~500 approved questions via the existing
gen→verify→score→approve→migrate pipeline, paced over many short re-runnable loops; resolve the dangling
#62 reference once.

**Current behavior:**
The full batch pipeline ran in late May 2026; all eight categories met their *original* targets and prod
pgvector was synced 2026-06-09 (308 then-approved; 565 total live). `general` sits at ~52 approved. The
TODO.md entry for #30 referenced a `#62` issue that has no file — a dangling reference.

**Desired behavior:**
The `general` category reaches ~500 approved questions in prod pgvector, reached incrementally across
runs. The `#62` reference is resolved. The issue stays open (with a running count) until ~500 is hit,
then flips to Done.

**Key interfaces / call paths:**
- `/generate-questions` skill — generates raw question batches for a named category; persists batch file to `data/questions/batch-NN-<category>.md`
- `/verify-questions` skill — runs Tavily-backed factual verification; sets `verify_status` on each question
- `/score-questions` skill — scores on 5 engagement dimensions; produces approve/revise/reject recommendation
- `PendingStore` (issue #27) — questions approved via `/questions/approve` endpoint land here before ChromaDB promotion
- `migrate_chroma_to_postgres.py` in `apps/quiz-pack-api/` — the migration script that pushes approved ChromaDB content to the prod pgvector store (run from `apps/quiz-pack-api/` cwd with `--approved-only` filter and `--execute` flag to make it non-dry-run)
- Prod pgvector store — queried via `GET /api/v1/questions?category=<cat>` to confirm count

**Acceptance criteria** *(plain bullets on purpose — these mirror tasks 30.G/30.M/30.done/30.docfix above; checkbox form would make Ralph pick them up as duplicate tasks)*:
- `GET /api/v1/questions?category=general` count climbs toward ~500 across runs (per-run: net-positive)
- Every newly approved question has non-empty `source_url` and `source_excerpt` fields
- New questions pass the ≥ 0.85-similarity dedup guard against existing `general` questions
- The issue-30 file header shows **Status:** Done only once `general` ≥ ~500
- No dangling `#62` reference remains in `docs/todo/TODO.md` pointing to a non-existent file

**Out of scope:**
- Re-verifying or re-scoring already-approved questions in any other category
- Adding categories beyond the eight defined in this issue
- Changing the scoring dimensions or approval thresholds
- Any iOS or backend API changes

**Suggested feedback loop:**
After each batch generation and approval cycle, query the local question store count by category. After the migration step (30.M), verify prod via `curl https://<prod-host>/api/v1/questions?category=general` and confirm the count rose. ~~Tasks 30.1–30.4 are self-contained batch units; 30.5 is the single migration gate; 30.6 is the doc cleanup close-out~~ *(stale task numbers from the dropped disney/football direction — the live tasks are 30.G/30.M/30.done/30.docfix above).*

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
