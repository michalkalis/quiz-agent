# Issue 22: ChromaDBClient — split query/write into a deeper QuestionStore seam

**Triage:** enhancement · ready-for-agent
**Status:** Surfaced by `/improve-codebase-architecture` 2026-04-30 — not started
**Created:** 2026-04-30
**Surfaced by:** architecture review, candidate #1

## TL;DR for next session

`packages/shared/quiz_shared/database/chroma_client.py` (680 lines) is a shallow
module: its interface (12+ public methods) is nearly as complex as its
implementation. It also mixes two concerns — *query/retrieval* (embeddings,
filter clause construction, semantic search) and *write/mutation* (add, update,
upsert, delete, backfill).

Two concrete symptoms:

1. **Duplicated metadata serialization.** `add_question` (lines 52–131) and
   `update_question_obj` (lines 477–555) are near-identical 80-line blocks.
   Both build the full metadata dict from a `Question`. A change to how a
   field is serialized must land in two places.
2. **Leaky abstraction.** `apps/quiz-agent/app/api/admin.py:265` reaches *past*
   the client and calls `chroma_client.collection.upsert()` directly, citing
   the known no-op behaviour of `update_question` documented in
   `project_chroma_update_bug` memory. Any caller of the client can do the
   same — the seam doesn't constrain.

## What to implement

Introduce a `QuestionStore` interface (the seam) with a narrow surface:

```
add(question)
upsert(question)        # canonical write — no silent no-op
get(id) -> Question?
delete(id)
search(query, filters) -> list[Question]
```

`ChromaDBQuestionStore` becomes the only adapter for now (one adapter =
hypothetical seam; two adapters = real seam — fine, the seam still earns its
keep by hiding metadata serialization).

Internally, extract a single `_question_to_metadata` helper that both `add`
and `upsert` call. The duplication disappears.

The admin bypass at `admin.py:265` becomes `store.upsert(question)`.

## Where the work lands

| Where | What changes |
|---|---|
| `packages/shared/quiz_shared/database/question_store.py` (new) | `QuestionStore` Protocol/ABC + `ChromaDBQuestionStore` adapter |
| `packages/shared/quiz_shared/database/chroma_client.py` | Either deleted entirely, or kept as a thin "raw client" used only by the new adapter for embedding access |
| `apps/quiz-agent/app/api/admin.py:265` | Replace `chroma_client.collection.upsert()` bypass with `store.upsert()` |
| `apps/quiz-agent/app/main.py` lifespan | Construct `QuestionStore` instead of (or wrapping) `ChromaDBClient` |
| `apps/quiz-agent/app/api/deps.py` | `get_question_store` dependency replaces or supplements `get_chroma_client` |
| All current callers of `chroma_client.add_question` / `update_question_obj` / `get_question` | Switch to the store interface |

## Benefits

- **Locality.** Metadata serialization changes in one place. The
  `project_chroma_update_bug` memory becomes irrelevant — `upsert` is the
  canonical write and never silently no-ops.
- **Leverage.** Callers get a small interface that hides ChromaDB's
  embedded-vs-flat result shapes, filter clause syntax, and metadata layout.
- **Testability.** The store interface can be mocked with an in-memory dict
  adapter for tests in `apps/quiz-agent/tests/` — no live ChromaDB required.

## Caveats and traps

- **Don't fold semantic search into the same interface as `get(id)`.** Search
  is a richer operation (filters, ranking) and should keep its own method;
  the goal is one *seam* (`QuestionStore`), not one method.
- **`question_retriever.py` already wraps some of this.** Coordinate with
  Issue 23 — the retriever is the *application-level* read path; the store is
  the *infrastructure-level* read path. Don't merge them.
- **Embedding generation lives in the client today.** Decide whether the new
  store owns embedding generation or accepts an embedder via constructor —
  prefer the latter so the embedder is its own seam.
- The `collection` attribute should become private after the bypass is
  removed.

## Related

- Memory `project_chroma_update_bug` — documents the silent no-op.
- Memory `project_prod_chroma_mount` — `CHROMA_PATH` must still match the
  mount point; no change here.
- Issue 23 (QuestionRetriever extension) is downstream — land 22 first.
