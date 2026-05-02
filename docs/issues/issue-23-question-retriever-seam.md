# Issue 23: QuestionRetriever — extend the seam to cover all question reads

**Triage:** enhancement · done
**Status:** Done 2026-05-02 — seam extended; reads in flow/quiz/voice/tts now go through `QuestionRetriever.get()` and `QuestionRetriever.count()`. Store field renamed `_store`. `QuizFlowService` no longer takes `question_store`.
**Created:** 2026-04-30
**Surfaced by:** architecture review, candidate #2

## TL;DR for next session

The question-access seam is half-built. `QuestionRetriever` owns "select the
next question" but "get a question by ID" bypasses it and goes straight to the
underlying `QuestionStore` (the seam introduced by #22).

Three call sites fetch by ID through the store directly, defeating the seam:

| Where | Current code |
|---|---|
| `apps/quiz-agent/app/quiz/flow.py:116` | `self.question_store.get(evaluated_question_id)` |
| `apps/quiz-agent/app/api/routes/quiz.py:202` | `store.get(session.current_question_id)` |
| `apps/quiz-agent/app/api/routes/quiz.py:209` | `store.get(session.current_question_id)` |
| `apps/quiz-agent/app/api/routes/voice.py:90` | `store.get(session.current_question_id)` |

`QuizFlowService` is constructed in `app/main.py:218–227` with **both** a
`question_retriever` and a raw `question_store`. The store is needed only
because the retriever's interface doesn't cover lookup-by-id.

Routes inject both via FastAPI deps (`get_question_retriever`,
`get_question_store`). Once the retriever covers `get(id)`, every route can
drop the `store` dep — or keep it only if it actually does writes (none of
these handlers do).

## What to implement

1. **Add a public lookup to `QuestionRetriever`:**
   ```python
   def get(self, question_id: str) -> Optional[Question]:
       return self.store.get(question_id)
   ```
   `apps/quiz-agent/app/retrieval/question_retriever.py:23` — the private
   `_get_recent_questions` helper at line 413 already uses `self.store.get(qid)`
   internally, so the implementation is trivial. (Optional: refactor
   `_get_recent_questions` to call the new public method to avoid two paths.)

2. **Hide the store on the retriever.** Currently `self.store` is public
   (line 32). Rename to `self._store`. Anything reaching into
   `retriever.store.<x>` becomes a compile/runtime error and forces routing
   through the seam. Update internal call sites in this file (search uses,
   `_get_recent_questions`, `_handle_no_candidates.count()`, etc.).

3. **`flow.py` — drop the redundant store arg.**
   - `apps/quiz-agent/app/quiz/flow.py:80` — remove `question_store: Any`
     constructor parameter and `self.question_store = question_store` at :89.
   - `apps/quiz-agent/app/quiz/flow.py:116` — replace
     `self.question_store.get(evaluated_question_id)` with
     `self.question_retriever.get(evaluated_question_id)`.
   - `apps/quiz-agent/app/main.py:218–227` — drop `question_store=...` from
     the `QuizFlowService(...)` wiring.

4. **`routes/quiz.py` — replace direct store reads with retriever:**
   - `:34` — keep `question_retriever` dep, drop `store=Depends(get_question_store)`
     unless the handler still needs writes (it doesn't).
   - `:190` — same: this handler only reads via `store.get` at :202 / :209.
   - `:202`, `:209` — replace `store.get(session.current_question_id)` with
     `question_retriever.get(session.current_question_id)`.

5. **`routes/voice.py` — same pattern:**
   - `:69` — drop `store=Depends(get_question_store)`.
   - `:90` — replace `store.get(...)` with `question_retriever.get(...)`.

6. **Tests.** Search for `question_store=` in tests (constructors of
   `QuizFlowService` and any route fixture) and remove the arg. Replace
   `store.get` mocks with `question_retriever.get`. The grep `rg
   "question_store|store\.get" apps/quiz-agent/tests` will surface them.

## Validation

- `pytest apps/quiz-agent/tests/ -v` — all pass.
- `grep -rn "question_store\|\.store\.get" apps/quiz-agent/app/` returns only
  internal references inside `QuestionRetriever` and the wiring in `main.py`
  (`question_store = chroma_client.store` at `:141`, passed only to the
  retriever constructor at `:162`). No application-layer leaks remain.
- Boot the backend (`uvicorn app.main:app --reload --port 8002`) and hit the
  endpoints touched (`/quiz/answer`, `/quiz/skip`, `/voice/...`) to confirm
  no DI signature regressions.
- `/verify-api` not required — no Pydantic model changes.

## Benefits

- **Leverage.** A read-through cache, telemetry, fallback, or tracing can be
  added in one module — `QuestionRetriever` — instead of N call sites.
- **Locality.** Question access is one concept with one home.
- **Testability.** Mocking the retriever in flow / route tests is sufficient.
  No need to mock both retriever and store.
- **Constructor noise reduction.** `QuizFlowService` shrinks one argument;
  routes shrink one DI dep.

## Caveats and traps

- **The retriever currently has retrieval-strategy logic** (next-question
  selection, fallback ladder, semantic diversity scoring). Don't conflate
  that with the new pass-through `get(id)` — the retriever is allowed to
  have both a strategy method and a simple lookup behind the same seam.
- **Don't reach into `retriever._store` from anywhere new.** The whole point
  of step 2 is to make the store private; if a future caller needs something
  the retriever doesn't expose, add a method to the retriever instead.
- **`question_store` is still needed in `main.py`** to construct the
  retriever (`QuestionRetriever(question_store=question_store)` at :162).
  That's fine — wiring is the right place for the raw store. Application
  layer is not.

## Related

- Issue 22 (QuestionStore split) — landed in `e6ecd47` 2026-04-30. This
  follow-up extends the seam upward.
- Memory `project_chroma_update_bug` — orthogonal but in the same area.
