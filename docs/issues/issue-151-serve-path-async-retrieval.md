# Issue 151: Question retrieval funnels through one background loop that a synchronous embedding call blocks

**Triage:** enhancement · needs-triage
**Priority:** serious
**Source:** architectural audit 2026-08-06
**Reversibility:** b (touches the shared store seam used by quiz-agent and the pack worker)
**Created:** 2026-08-06

## Context

Serving a question is the product's hot path: the player asks, the app must answer inside the voice loop. Today every single question lookup in quiz-agent — first question, next question, TTS re-read, answer resubmission — is routed through one process-wide bridge thread, and each lookup parks that thread for a full remote embedding round trip to OpenAI before it even touches the database. The result is a hard throughput ceiling of roughly one retrieval at a time for the whole process: two players quizzing at once queue behind each other's embedding latency rather than overlapping. No user count today exposes this (prod is founder-only), but the seam gets more expensive to unpick with every caller that binds to the synchronous store, so this is worth fixing while it is still one session of work.

## Confirmed findings

### 1. Every retrieval runs a synchronous embedding HTTP call inside the async store, on a single shared loop thread

**Severity:** serious · confirmed by adversarial verification (2026-08-06)

**`packages/shared/quiz_shared/database/pgvector_client.py:246`** — inside `async def search` (declared at :231):

```
query_embedding = self._embedder(query_text) if query_text else None
```

The embedder is synchronous by default: `embedder: Embedder = generate_embedding` (`pgvector_client.py:131`), and `generate_embedding` ends in a blocking call on a synchronous OpenAI client — `response = client.embeddings.create(model=resolved, input=text)` (`packages/shared/quiz_shared/utils/embeddings.py:50`). Only the client object is cached; there is no embedding cache, so identical semantic query strings pay a full round trip every time.

The serve path always embeds. `QuestionRetriever._retrieve_candidates_semantic` calls the store with a query text unconditionally — see the comment `# ALWAYS use semantic search (RAG-first approach)` at `apps/quiz-agent/app/retrieval/question_retriever.py:280` followed by `self._store.search(...)` at :281 — and the three fallback paths (:328, :344, :360) also pass a `query_text`.

There is exactly one bridge for the whole process. `apps/quiz-agent/app/main.py:157-160` constructs one `PgvectorQuestionStore` and wraps it in one `SyncPgvectorStore` at startup, which is then handed to `QuestionRetriever`. Its per-instance `_BackgroundLoop` is therefore a de-facto process singleton, and every `get` / `count` / `search` from every request goes through `asyncio.run_coroutine_threadsafe(coro, loop)` → `future.result()` (`packages/shared/quiz_shared/database/sync_pgvector_store.py:59-60`).

**Impact.** The blocking embedding call happens *inside* the coroutine, before `async with self._session_factory()`, so it never yields — queued retrieval coroutines on that loop cannot interleave with it. The `asyncio.to_thread(...)` wrappers at the nine call sites (`api/routes/quiz.py:124,311`, `quiz/flow.py:171,248`, `api/routes/voice.py:96,159`, `api/routes/tts.py:84`, `quiz/resubmission.py:188,275`) do free the FastAPI event loop, but they all converge on the same serialized bridge — they give a false impression of parallelism. And `future.result()` at :60 carries no timeout, so nothing on the caller side can break a stalled retrieval.

**Two corrections to the original audit wording, both verified:**

- The embedding call is *not* unbounded. `openai_client()` defaults to `DEFAULT_TIMEOUT = httpx.Timeout(30.0, connect=5.0)` (`packages/shared/quiz_shared/llm/factory.py:59`, applied at :239), chosen precisely so the voice hot path never inherits the SDK's 600s default. A stalled embedding fails in ~30s × SDK retries, not forever.
- The genuinely unbounded legs are the pgvector query itself (no statement timeout on the async engine) and the untimed `future.result()`.

So "same hang shape as #139 — pack generation hang observability" is overstated. The concrete defect is a **process-wide throughput ceiling** on the core serve path (order of one retrieval per embedding round trip), plus an unbounded bridge wait. Severity stays serious.

**Not previously tracked, not a decided constraint.** #139's bridge work was a different defect on the generation path (the bridge gets its own engine, to fix cross-loop asyncpg pooling); no issue in `docs/issues/INDEX.md` covers serve-path retrieval serialization. The `_BackgroundLoop` docstring argues only for a background loop over `asyncio.run` as the sync→async mechanism; it never argues that serializing retrieval is acceptable. A blocking LLM call on the serve path also runs against the standing `feedback_hot_path_llm_minimalism` preference.

### 2. (Secondary, same root cause) `find_duplicates` embeds synchronously too

**Severity:** minor · **unverified** — noted while reading, not independently confirmed and not part of this issue's acceptance.

`pgvector_client.py:283` repeats the same `self._embedder(question_text)` pattern inside `async def find_duplicates` (:270). That is the pack worker's `DedupStage` path, not the serve path, so it does not affect the voice loop — but it is the reason the synchronous `QuestionStore` shape cannot simply be deleted: fixing quiz-agent must not strand the worker's sync caller.

## Proposed approach

Conceptual, one session, scoped to `apps/quiz-agent` plus `packages/shared`:

1. **Make the serve read path async end to end.** Have the FastAPI routes and `QuestionRetriever` await `PgvectorQuestionStore` directly instead of going through `SyncPgvectorStore`, and drop the `asyncio.to_thread` wrappers at the nine call sites. Retrieval then runs on the request's own event loop, so concurrent players overlap naturally.
2. **Use an asynchronous embedder for the async store.** Add an async embedding function alongside `generate_embedding` and make it the default the async store uses, so the embedding round trip awaits instead of parking a thread. Keep the existing synchronous function for the synchronous callers.
3. **Keep the sync facade alive for the worker, but bound it.** `SyncPgvectorStore` stays for `DedupStage` and the admin/write callers; give its bridge wait an explicit timeout so a stalled coroutine surfaces as a loud error rather than a silent park.
4. **Bound the database leg.** Set a statement timeout on the async engine used for retrieval so a slow pgvector query fails visibly inside the voice loop's budget instead of hanging.
5. **Consider (do not assume) an embedding cache.** Semantic query strings on the serve path repeat heavily. Cheap win, but decide it on measurement, not assumption — keep it out of scope unless step 1 alone does not clear the latency bar.

Non-goals: no change to retrieval ranking, filters, or fallback ordering; no change to the pack generation pipeline's model stack.

## Done criteria

- [ ] No serve-path retrieval call reaches `SyncPgvectorStore`: no `asyncio.to_thread(question_retriever...)` remains in `apps/quiz-agent/app`, and `QuestionRetriever` holds an async store.
- [ ] The embedding call on the serve path is awaited, not blocking: `PgvectorQuestionStore.search` no longer invokes a synchronous OpenAI client on the loop it runs on.
- [ ] A concurrency test proves overlap: N simultaneous question requests against a stubbed embedder with a fixed delay complete in about one delay, not N delays. This test must fail on the current code.
- [ ] `SyncPgvectorStore.run` uses a bounded wait; a test asserts a hung coroutine raises a timeout instead of blocking forever.
- [ ] The pack worker's `DedupStage` path still works — `apps/quiz-pack-api` suite green (`LLM_GATEWAY=direct` pinned).
- [ ] `apps/quiz-agent` suite green; a live quiz run (first question → answer → next question) verified against the deployed backend.
- [ ] Deployed to prod, and the p50/p95 for `get_next_question` under two concurrent sessions is recorded in this file as a before/after datapoint.
