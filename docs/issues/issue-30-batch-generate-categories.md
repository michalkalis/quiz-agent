# Issue 30: Batch-generate questions for new categories

**Triage:** enhancement · ready-for-agent
**Status:** Open
**Created:** 2026-05-02
**Surfaced by:** Split of #21 (Groups B-E). This is **Group E** of `question-pipeline-remaining.md`. Now unblocked by #27 (PendingStore) and Group A skills.

## TL;DR

Run the gen → verify → score → approve → import pipeline at volume to fill the new categories with quality content. Targets:

| Category | Type | Target count |
|---|---|---|
| `kids` | core | 50 |
| `general` | core | 50 |
| `adults` | core | 50 |
| `wizarding-world` | themed | 30 |
| `superheroes` | themed | 30 |
| `disney` | themed | 30 |
| `football` | themed | 30 |
| `sports-mix` | themed | 30 |

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
