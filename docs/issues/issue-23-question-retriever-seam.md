# Issue 23: QuestionRetriever — extend the seam to cover all question reads

**Triage:** enhancement · ready-for-agent
**Status:** Surfaced by `/improve-codebase-architecture` 2026-04-30 — not started
**Created:** 2026-04-30
**Surfaced by:** architecture review, candidate #2

## TL;DR for next session

The question-access seam is half-built. `QuestionRetriever` owns "get the next
question" but "get a question by ID" bypasses it and goes straight to the
ChromaDB client.

Concrete leaks:

| Where | Code |
|---|---|
| `apps/quiz-agent/app/quiz/flow.py:116` | `self.chroma_client.get_question(evaluated_question_id)` |
| `apps/quiz-agent/app/api/routes/quiz.py:202,209` | `chroma_client.get_question(...)` |
| `apps/quiz-agent/app/api/routes/voice.py:90` | `chroma_client.get_question(...)` |

`QuizFlowService` is constructed in `main.py:218–227` with **both** a
`question_retriever` and a raw `chroma_client`. The raw client is needed only
because the retriever's interface doesn't cover `get_by_id`.

## What to implement

Add `get_question(id) -> Question?` to `QuestionRetriever`'s interface and
remove all direct `chroma_client.get_question` calls from the application
layer.

After that lands, `QuizFlowService` no longer needs a `chroma_client`
constructor argument — drop it. The route handlers in `routes/quiz.py` and
`routes/voice.py` switch to the retriever as well.

## Where the work lands

| Where | What changes |
|---|---|
| `apps/quiz-agent/app/retrieval/question_retriever.py` | Add `get_question(id)` method; delegates to the underlying store |
| `apps/quiz-agent/app/quiz/flow.py:86–90, 116` | Drop `chroma_client` constructor arg; replace direct call with `self.question_retriever.get_question(...)` |
| `apps/quiz-agent/app/main.py:218–227` | Drop `chroma_client` from the `QuizFlowService` constructor wiring |
| `apps/quiz-agent/app/api/routes/quiz.py:202,209` | Replace `chroma_client.get_question` with retriever |
| `apps/quiz-agent/app/api/routes/voice.py:90` | Same |

## Benefits

- **Leverage.** A read-through cache, telemetry, or fallback strategy can be
  added in one module — `QuestionRetriever` — instead of N call sites.
- **Locality.** Question access is a single concept with a single home.
- **Testability.** Mocking the retriever in flow / route tests is now
  sufficient. No need to mock both the retriever and the client.
- **Constructor noise reduction.** `QuizFlowService` shrinks one argument.

## Caveats and traps

- **Order matters with Issue 22.** If 22 lands first and replaces
  `ChromaDBClient` with `QuestionStore`, then 23 becomes "make
  `QuestionRetriever` wrap `QuestionStore`, expose `get_question`, and route
  all reads through it." Either order works; just don't bundle them — they
  are independent commits.
- **The retriever currently has retrieval-strategy logic (next-question
  selection, deduplication).** Don't conflate that with the new pass-through
  `get_question` — the retriever is allowed to have both a strategy method
  and a simple lookup method behind the same seam.
- **Don't reach into `chroma_client.collection` from anywhere new.** Once 22
  lands, that attribute should be private.

## Related

- Issue 22 (QuestionStore split) — ideal predecessor.
- Memory `project_chroma_update_bug` — orthogonal but in the same area.
