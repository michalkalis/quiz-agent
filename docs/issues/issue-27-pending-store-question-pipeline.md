# Issue 27: Question pipeline — introduce a `PendingStore` seam

**Triage:** enhancement · ready-for-agent
**Status:** Surfaced by `/improve-codebase-architecture` 2026-04-30 — not started
**Created:** 2026-04-30
**Surfaced by:** architecture review, candidate #6

## TL;DR for next session

The gen-verify-score pipeline has a hole: the pending/approved distinction
that the `Question.review_status` field was designed to represent has no
storage. The end-to-end pipeline cannot run autonomously.

Concrete failures:

1. **`POST /api/v1/import` is a stub.** `apps/question-generator/app/api/routes.py:139–168`
   accepts a list of question dicts, builds `Question` objects, returns their
   IDs, and writes nothing. The TODO comment is explicit:
   *`# TODO: Implement pending review storage / For now, just return the IDs`*.

2. **`POST /questions/approve` only sees ChromaDB-resident questions.**
   It calls `storage.get_question(qid)`, which retrieves from `ChromaDBClient`.
   So you can only approve questions already stored — meaning the pipeline
   only works when generation writes directly to ChromaDB and `import` is
   unused. External LLM output goes nowhere.

3. **`QuestionStorage`** wraps `ChromaDBClient` with a thin approval layer.
   The "pending but not yet approved" state has no home. `review_status`
   exists on the model but nothing reads or writes it for that state.

This blocks the **Group A → Groups B-E** roadmap (per
`project_question_quality` memory) — Groups B-E need to be importable in
batches, reviewed asynchronously, and approved selectively.

## What to implement

Introduce a `PendingStore` interface: a separate store for questions in
`pending_review` / `needs_revision` state. Implementation can be SQLite (the
existing ratings store), a flat JSON sidecar in `data/`, or a small ChromaDB
collection — pick the simplest that fits.

Pipeline shape after the change:

```
generate ──► PendingStore (review_status=pending_review)
              │
              ├─► /verify-qs  ──► PendingStore (updates source_url, source_excerpt)
              ├─► /score-qs   ──► PendingStore (updates scores)
              │
              └─► approve     ──► reads from PendingStore, writes to ChromaDB,
                                  removes from PendingStore
```

`POST /import` writes to `PendingStore`. `POST /approve` reads from
`PendingStore` and promotes to `ChromaDB`. The `web/routes.py` reviewer UI
displays pending and approved separately.

## Where the work lands

| Where | What changes |
|---|---|
| `packages/shared/quiz_shared/database/pending_store.py` (new) | `PendingStore` interface + chosen adapter |
| `apps/question-generator/app/api/routes.py:139–168` | Replace `# TODO: Implement pending review storage` with `pending_store.add(question)` |
| `apps/question-generator/app/api/routes.py` (approve route) | Read from `PendingStore`, write to ChromaDB, delete from `PendingStore` |
| `apps/question-generator/app/storage/question_storage.py` | `QuestionStorage` becomes the orchestrator over `PendingStore` + ChromaDB store |
| `apps/question-generator/app/web/routes.py` | Reviewer UI: separate "pending" vs "approved" lists |
| `scripts/generate_questions_claude.py`, `scripts/verify_questions.py`, `scripts/score_questions.py` | Write to `PendingStore` instead of ChromaDB; respect `review_status` |
| `apps/question-generator/tests/` | New tests for the pending → approved transition |

## Benefits

- **Leverage.** The pipeline becomes runnable end-to-end without manual
  intervention. Groups B-E can be batched.
- **Locality.** The pending state machine lives in one module. The
  `review_status` field has a single home.
- **Testability.** `PendingStore` can be mocked with an in-memory adapter
  for the approve flow tests — no ChromaDB needed.
- **Decouples generation from approval.** External LLM output (`/import`)
  finally has a place to land.

## Caveats and traps

- **Coordinate with Issue 22.** If `QuestionStore` lands first, `PendingStore`
  should follow the same shape (Protocol/ABC + adapter). They are siblings,
  not the same module.
- **Don't store pending questions in the production ChromaDB collection
  with a flag** — that pollutes semantic search at retrieval time. Use a
  separate store, even if it's a different ChromaDB collection.
- **Migration**: there are likely already half-pending questions in the
  current store with `review_status` set. Decide whether to migrate or to
  treat the new store as forward-only. Forward-only is simpler.
- **Path conventions**: if SQLite, follow the same `data/` mount convention
  ChromaDB uses (memory: `project_prod_chroma_mount`). Add a corresponding
  Fly secret if needed.
- **Don't conflate this with the `question-generator` service split.** The
  service architecture is fine; this is a storage seam.

## Related

- Memory `project_question_quality` — Group A operational, Groups B-E queued.
- Memory `project_chroma_update_bug` — orthogonal but in the same area.
- `apps/question-generator/app/api/routes.py:139–168` — the actual TODO.
- Issue 22 (QuestionStore split) — same family; share the interface shape.
