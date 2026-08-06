# Issue 152: Arch review 2026-08 — small findings collector

**Triage:** bug · needs-triage
**Priority:** attention
**Source:** architectural audit 2026-08-06
**Reversibility:** a (every item is a small, independently revertable change)
**Created:** 2026-08-06

## Context

The 2026-08-06 architectural audit produced a tail of findings that are individually too small to justify their own issue file, but collectively cover the paid paths: session correctness, generation observability, client/server contract drift, and cost accounting. None is an emergency — prod is founder-only — but most share the same shape: a guard, counter, or comment that *claims* a property the code does not have, so the failure mode is invisible rather than loud. This file is the working queue for one triage session; the sub-sections are ordered so a single pass can work top to bottom.

14 findings were adversarially re-verified (marked **verified**); 19 were left at first-pass confidence (marked **unverified** — confirm the cited line before acting). Severity for every item is *minor*: cheap now, cheap later, no data loss in flight.

## Confirmed findings

### A. Session-lifecycle correctness (quiz-agent)

**backend-2 — #133 retry-idempotency does not hold for the last question** · `apps/quiz-agent/app/quiz/flow.py:215` · **verified**
- On the final answer `if len(session.asked_question_ids) >= session.max_questions:` transitions to `SessionPhase.FINISHED` and persists (flow.py:216-219). Both submit routes gate on phase *before* classification (`voice.py:78`, `quiz.py:244`: `raise HTTPException(400, "Not waiting for input")`), so `classify_submission` (`resubmission.py:94`) is never reached for a re-sent final `question_id`. Same hole on the quota-exhausted branch (flow.py:232).
- Impact: nothing is double-graded or double-charged (the gate blocks all mutation) — but a lost response on the last submit is unrecoverable, since `SessionResponse` (deps.py:466) carries no evaluation. Surfaces as "iOS sometimes shows 9 of 10 results" and gets debugged client-side. iOS auto-retries the upload with the same id (`RecordingCoordinator+Submission.swift`), so it is reachable.
- Fix: classify before the phase gate, or admit FINISHED when `submitted_question_id == session.last_evaluation.question_id`. Add a test for a finished session (`tests/test_idempotent_submit.py` covers only mid-quiz).

**backend-4 — `update_session` failure ignored at all 8 call sites** · `apps/quiz-agent/app/session/manager.py:245` · **verified**
- `if session.session_id not in self._sessions: return False`, and every caller discards the bool (flow.py:219/234/256/282, resubmission.py:228, quiz.py:190, tts.py:109, sessions.py:130). `_cleanup_expired` (manager.py:145-160) holds only the threading lock, not the per-session `asyncio.Lock` the submit routes take, and runs on the same loop. The quota charge (`record_question`, flow.py:269) precedes the write (flow.py:282).
- Impact: narrow today — `get_session` 404s an already-expired session before any charge, and iOS extends the TTL 30 min after every answer, so the window is one in-flight submit after ~30 min idle. But the swallowed return gets materially worse when sessions move out of process memory to Postgres/Redis (the migration the class docstring at manager.py:30-34 already mandates), where writes fail for reasons other than expiry.
- Fix: make the write checked (raise, or a 409/410 the flow surfaces) and refresh `expires_at` on every successful write instead of relying on the client's fire-and-forget `/extend`.

### B. Serve-path hygiene (quiz-agent)

**backend-5 — "parallel prefetch" is serial, plus a duplicate question fetch** · `apps/quiz-agent/app/api/routes/voice.py:158` · **verified**
- `next_question_task = asyncio.create_task(...)` at :158 is awaited at :163-164 with no intervening await; the comment above claims "Parallel next-question prefetch" and was never accurate (introduced serial in `bcc12e8c`). `get_next_question` is an embedding call plus a pgvector query (`question_retriever.py:65`). Separately voice.py:96-98 fetches the question by id and `flow.process_answer` re-fetches the same id at flow.py:171-173.
- Impact: retrieval latency sits strictly between transcription and evaluation on the hands-free path where latency *is* the product. The misleading comment sends the next optimiser elsewhere.
- Fix: start the prefetch task *before* the transcription await (session state is not mutated during transcription). Note the original fix sketch's "await after `process_answer`" is impossible — `next_question` is an input to it. The duplicate `get` is a cheap id lookup and the voice-side copy is load-bearing (Whisper priming + leakage check), so deduping needs a signature change; low value, optional.

**backend-8 — question store bypasses the hardened engine builder** · `packages/shared/quiz_shared/database/pgvector_client.py:138` · *unverified*
- `engine = create_async_engine(database_url)` — bare, while `quiz_shared.database.engine.build_engine` sets `pool_size`, `pool_pre_ping=True`, `future=True` and is what the auth/usage side uses. `settings.db_pool_size` (config.py:59) never reaches the question store; both engines hit the same Fly cluster.
- Impact: the hot read path is the one pool without pre-ping, so an idle-killed connection becomes an `OperationalError` on a player's answer (a non-retryable 500 on the voice route) instead of a transparent reconnect. Two construction paths means every future hardening fix must be remembered twice.
- Fix: build the pgvector engine via `build_engine(database_url, pool_size=settings.db_pool_size)`.

**backend-9 — unparseable evaluator verdict scores the player "incorrect"** · `apps/quiz-agent/app/evaluation/evaluator.py:231` · *unverified*
- `# Default to incorrect if unclear` / `return "incorrect"` with no log, no Sentry, no distinct verdict. Just above, `response.choices[0].message.content.lower()` assumes non-None content — a refusal raises `AttributeError` → generic 500.
- Impact: a provider formatting glitch is indistinguishable from a wrong answer, both to the player and in telemetry. #142 already tracks non-JSON provider responses on the generation side; the serve side has the same exposure with a wrong-verdict outcome and no detector.
- Fix: log + `capture_message` on the unparsed branch with the raw text, and guard `content` for None.

**backend-10 — TTS-leakage detector warns and then grades anyway** · `apps/quiz-agent/app/api/routes/voice.py:141` · *unverified*
- `if similarity > 0.5: logger.warning("Transcription %.0f%% similar to question - possible TTS leakage", ...)`; the >100-char check at :136-140 likewise only warns. Execution falls through to the paid evaluation at :167.
- Impact: a detected-bad input is transcribed, evaluated, given a verdict and charged against quota. The detector exists with no consequence, so mic-bleed stays invisible in aggregate and unrecoverable for the player.
- Fix: either reject with the 400 the low-confidence branch already uses, or attach the flag to the response/Sentry so the rate is measurable. Do not leave a detector with no action.

### C. Pipeline observability and fail-open behaviour (quiz-pack-api)

**packapi-3 — generation core reports swallowed failures via `print()`** · `apps/quiz-pack-api/app/generation/advanced_generator.py:1821` · **verified**
- 1842 lines, zero `logger.` calls, no `import logging`, 27 `print(...)`. Several are the sole record of a swallow-and-continue: MCQ sub-batch failure (:668 → `return []`), judge pair skipped (:1672 → `return None`), critique attempt failed (:1756), parse bails (:1792, :1821, :1828). Sentry's `LoggingIntegration` and the JSON formatter (`app/logging_config.py:50`) both only see logging records, so none of these reach Sentry, `step_log`, or an `order_id` correlation. The orchestrator layer one level up (`stages/generation.py:37`) does use the standard plumbing.
- Impact: yield loss inside generation is unstructured and uncorrelated — a batch parsing to 5 of 30 surfaces only later as a top-up floor failure with no cause attached.
- Fix: module logger; convert the ~8 exception-path prints to `logger.warning/exception`, keep verbose progress prints behind `self.verbose`.

**packapi-6 — kept-count reported as "verified", hiding held-for-review questions** · `apps/quiz-pack-api/app/orchestrator/stages/verification.py:140` · **verified**
- `info={"verified": len(kept), "dropped": dropped}` — `kept` includes every `held_for_review` (lines 129-131), every no-verdict question (104-109), and `uncertain` above threshold. `FactVerifier` holds when Tavily is down (:171) and `_complete` swallows every LLM exception to `None` (:146) → `_judge_unusable` → held (:326).
- Impact: a pack generated during a Tavily outage reports `verified: 30` with zero facts checked. Ground truth *is* persisted per question (`extra["verified"]`, `extra["held_for_review"]` at :120-125) and held questions still face the scoring gates, so nothing is lost — but the one operator-facing metric cannot detect a degraded run.
- Fix: split the counter into `verified` / `held_for_review` / `dropped`; consider failing loud above a held fraction.

**packapi-8 — heartbeat fails silently; sweep timeout reasons from a stale constant** · `apps/quiz-pack-api/app/worker/tasks.py:66` · *unverified*
- `_job_heartbeat`'s only handling is `except Exception: logger.warning(...)` (66-68) — no consecutive-failure escalation, no Sentry — and nothing else writes `generation_jobs.updated_at` during a stage. Sweep liveness is purely that column (`sweep.py:94`), while `job_timeout` is now 3600s (worker.py:158) and the sweep comment still reasons from 600s (`sweep.py:49-53`): a 15-min recovery window against a 60-min job budget.
- Impact: a sustained heartbeat outage during a long run lets the sweep classify a live, still-billing pipeline as dead and start a second one — double LLM/Tavily spend plus an orphaned pack.
- Fix: escalate after N missed beats (Sentry, ideally abort), and derive `IN_PROGRESS_STUCK_TIMEOUT` from `job_timeout` so they cannot drift.

**packapi-9 — no schema-level order→pack uniqueness; the ON CONFLICT guard is decorative** · `apps/quiz-pack-api/app/orchestrator/stages/persist.py:64` · *unverified*
- The stage unconditionally does `pack = QuestionPack(order_id=order.id, ...)` (64-76), justified in its docstring by a 1:1 "enforced at the worker layer" — but `question_packs` has no unique constraint on `order_id` (`app/db/models/pack.py:31-49`) and the worker only assigns `order.pack_id` (tasks.py:199). `on_conflict_do_nothing(index_elements=["id"])` (:84) never fires because a fresh run mints new question ids (:114).
- Impact: a duplicate run (sweep re-enqueue racing a live job) leaves an orphaned pack plus a duplicate question set in the shared corpus, silently feeding later dedup.
- Fix: unique index on `question_packs.order_id` and upsert per order, so a second run fails loud.

**packapi-10 — corpus dedup fails open and the promised signal is never emitted** · `apps/quiz-pack-api/app/orchestrator/stages/dedup.py:114` · *unverified*
- `except Exception: # ... surface via info but do not drop the question on a store outage` → `return False`. Nothing is counted, logged, or added to `StageResult(info=...)` (104-107). The corpus check is the only cross-order duplicate guard.
- Impact: a pgvector/embedding outage turns dedup into a no-op for the whole order while the step log looks healthy. The comment asserts a safeguard that does not exist.
- Fix: count store failures into `StageResult.info` (`store_errors`) and fail the stage above a small fraction.

**packapi-11 — SSE replay reports progress 0 for every historical step** · `apps/quiz-pack-api/app/sse/bridge.py:44` · *unverified*
- `_make_event` fills `entry.get("progress", 0)`; the replay loop admits the gap (90-92). The writer confirms it: `DBProgressSink.start_step` persists only `{step, info, started_at}` (`progress_sink.py:78-87`) while real progress goes only to the transient Redis channel (:105-110).
- Impact: any reconnect — the exact case `Last-Event-ID` exists for — replays a 10-minute-old paid order at 0%. Clients will end up reconstructing progress from step names, coupling the app release to server stage ordering.
- Fix: persist `progress` in the `step_log` entry (already computed in `PackGenerator.run` before `publish`) and emit it on replay.

### D. Client/server contract drift

**contract-2 — #103 shortfall + refund signals never landed on iOS** · `apps/ios-app/Hangs/Hangs/Models/PackOrder.swift:107` · **verified**
- Backend sends `actual_count` (`orders.py:142`, populated at :475-489/:534-541) and `refund_eligible` (:149). iOS `OrderSnapshot` (107-141) declares neither; a repo-wide grep for `actualCount|refundEligible` in the app returns nothing. `HomePacksSection.swift:80` renders `Text("\(order.targetCount) questions")`, and `topup.py:44 FLOOR_FRACTION = 0.8` makes a 24-of-30 pack a normal `delivered` order.
- Impact: user pays for 30, receives 24, UI says 30 — the exact silent failure #103 F5 was filed to close. (Correction to the audit's framing: #103's own scope was backend-only, so this is uncovered follow-on work, not a false DONE. The `refund_eligible` half is weak — refunds run through Apple, and iOS already shows a retryable failure message at `OrderPackViewModel.swift:420`.)
- Fix: add `actualCount: Int?` (and optionally `refundEligible: Bool`) to `OrderSnapshot`; render actual-vs-target when they differ. Two additive Codable fields, no migration; the true count is already durable in `question_packs.actual_count`.

**contract-4 — `/extend` binds `minutes` as a query param; iOS sends a JSON body** · `apps/quiz-agent/app/api/routes/sessions.py:164` · *unverified*
- `minutes: int = 30` with no `Body(...)` → FastAPI binds it as a query parameter. `NetworkService.swift:309-315` encodes `["minutes": minutes]` as the body with no query item, so the server always applies its own default and returns 200. Invisible only because the sole call site passes the same 30 (`QuizViewModel.swift:1701`).
- Impact: the first time anyone changes the iOS value, nothing happens and nothing fails.
- Fix: `minutes: int = Body(30, embed=True)`, or send `?minutes=` from iOS. Pick one and note it in the route docstring.

**contract-5 — raw wire `category` strings rendered verbatim in the quiz UI** · `apps/ios-app/Hangs/Hangs/Views/QuestionView.swift:155` · *unverified*
- `Text("\(question.category) · Q\(currentQuestionNumber)")` (:155), also :205, :208, and `SetRecapView.swift:61`. `category` is a corpus wire id (`Config.swift:96-106`: `"wizarding-world"`, `"sports-mix"`, …) and `serializers.build_question_translation` never translates it. A localized map already exists (`QuizSettings.swift:238 categoryDisplayName()`), and `PackOrder.swift:154-170 statusLabel` codifies the rule for order status (#137: raw wire values must never be rendered).
- Impact: with the #130 UI-language split shipped, a Slovak player sees "wizarding-world · Q3". Structurally, the category vocabulary becomes a UI-visible contract.
- Fix: route both call sites through `categoryDisplayName(for:)` with a raw-id fallback like `statusLabel`.

**contract-6 — iOS `Question` declares six fields the wire can never send** · `apps/ios-app/Hangs/Hangs/Models/Question.swift:30` · *unverified*
- `language`, `packId`, `promptSeed`, `embeddingModel`, `embeddingDim`, `costCents` (30-35, CodingKeys 66-71). `PublicQuestionWire` (`packages/shared/quiz_shared/models/question.py:414-436`) carries none of them and `from_question` (:474-493) never populates them. No call site reads any of the six.
- Impact: six permanently-nil fields that look like live contract — a debugging trap inside the model the whole app reads.
- Fix: delete them (or add to the wire model if any is actually wanted). `Question.swift`'s header already documents this discipline for `headlineAnswer`.

**contract-7 — two wire encodings for `POST /v1/orders`, one absent from OpenAPI** · `apps/quiz-pack-api/app/api/v1/orders.py:208` · *unverified*
- Declared `status_code=202, response_model=OrderCreatedResponse` (Pydantic datetime → `…Z`), but the idempotent replay returns a hand-built `JSONResponse(200, {... "created_at": existing.created_at.isoformat()})` (`_idempotent_replay_response`, 208-224, used at :321 and :379) with `# type: ignore[return-value]` hiding the mismatch — `isoformat()` yields `+00:00`. FastAPI documents only the 202. `PackOrderService.swift:126` decodes `createdAt` as `String`, so nothing surfaces it.
- Impact: the moment a client parses `createdAt` as a date, the replay path is the case that breaks — the harder one to reproduce.
- Fix: build the replay body from `OrderCreatedResponse.model_validate(existing, from_attributes=True)` via `jsonable_encoder`, and declare `responses={200: {"model": OrderCreatedResponse}}`.

**contract-8 — per-order LLM COGS shipped to every client** · `apps/quiz-pack-api/app/api/v1/orders.py:144` · *unverified*
- `llm_cost_usd` and `search_cost_cents` (145-146) are returned by both order endpoints to any owning bearer (`_order_snapshot`, 440-441). The only mitigation is a code comment: "fine to expose while prod is founder-only — hide behind the admin key before real users." iOS decodes them (`PackOrder.swift:122-123`) and renders neither; nothing in `docs/` tracks the removal.
- Impact: a pre-GA gating step exists only as a comment. Once real users exist, per-pack cost of goods is one `curl` away and nothing will remind anyone.
- Fix: gate both on `admin_key_presented(request)` in `_order_snapshot` now — zero client impact — rather than leaving it as a comment.

### E. iOS lifecycle papercuts

**ios-2 — `.processing` maps to the confirmation command screen with no sheet present** · `apps/ios-app/Hangs/Hangs/ViewModels/VoiceCommandCoordinator+Listening.swift:46` · **verified**
- `currentCommandScreen` keys purely off phase (`case .processing: return .confirmation`), vocabulary `[.ok, .again, .stop]`. A tap-submitted MCQ goes `.askingQuestion → .processing` without tearing the listener down. `rerecordAnswer()` guards only on the phase (`RecordingCoordinator+Confirmation.swift:96`) and `cancelProcessing()` (:120) has no guard; both roll back to `.askingQuestion`, after which `handleQuizResponse` drops the in-flight response (`QuizViewModel.swift:1605`).
- Impact: bounded, not divergent — #133 1a's resubmission classifier replays the verdict and resyncs on the next submit, and a genuinely stale id gets a modelled 409. Real defect: on tap-MCQ / typed evaluation there is no sheet, yet `.ok`/`.again`/`.stop` are live and invisible; "again" opens the mic unexpectedly. (Two audit claims did not survive: the stale ListenBar hint only appears on the voice screen, and bare "no" is deliberately excluded as a stop variant.)
- Fix: gate `case .processing` on `showAnswerConfirmation` (injected reader) and return nil otherwise; add the same precondition to `rerecordAnswer()` and `cancelProcessing()`.

**ios-4 — result-feedback playback runs in an untracked Task** · `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:1737` · **verified**
- Bare `Task { ... }` with no `taskBag.add(...)`, against the file's own comment (813-819) recording that exactly this pattern was a prior regression, and `endQuizWithResults()` (1472-1484) relying on `taskBag.cancelAll()` as the single teardown lever. Same escape at `QuizTimersController.swift:318` and `QuizViewModel.swift:1537/1549/1558`.
- Impact: less than the audit claimed — the countdown registers itself in the bag before a tap can be processed, and `stopAnyPlayingAudio()` really does cancel playback. What remains reachable: after playback stops, the feedback tail (`AudioDeviceState+Playback.swift:167-180`) still runs `startSilenceDetectionListening()` with no quiz-state guard, re-arming the mic *after* `deactivateSession()` — the #119/#64 family.
- Fix: **task-bag registration alone will not fix this** — Swift cancellation is cooperative and none of the awaits check `isCancelled`. Add a quiz-state/generation guard in the feedback tail before re-arming; register the task under a `TaskKey` as hygiene.

**ios-5 — a deferred StoreKit approval is captured but nothing redeems it** · `apps/ios-app/Hangs/Hangs/Services/PackPurchaseService.swift:149` · *unverified*
- `makeUpdatesListener` persists the proof for an Ask-to-Buy/SCA approval that clears later (149-162). The only reader of `pendingProof()` is `OrderPackViewModel.resolvePaymentProof()` (:376), reachable only from `submit()`/`retry()` — the user must voluntarily reopen Settings → Create pack. Nothing at launch inspects it; `PackPurchaseError.pending` maps to a generic retryable failure (304-306).
- Impact: a charge that clears hours later leaves a paid-for proof in UserDefaults with no notification and no order. Ask-to-Buy is exactly the family audience packs target.
- Fix: check `pendingProof()` at launch (AppState already constructs the service) and surface a durable entry point — e.g. a MyPacks banner that opens the order form pre-armed to spend it.

**ios-6 — `QuizState` equality ignores associated values** · `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:36` · *unverified*
- Cases compared by label only (36-51), `validTransitions` keyed on the label (:83), and `.error → .error` is not allowed (:99). `setError` writes `activeErrorModel` (:1016) *before* the rejected transition (:1019), so a second failure updates the displayed model while the state payload keeps the first error's `(message, context)`. `retryLastOperation()` (:1219) and `shouldRetryWithNewSession` (:1210) branch on the stale context while ContentView renders the new model (:135).
- Impact: the error screen can show one failure's copy while the retry button runs the other's recovery. The same payload-blind equality makes `.onChange(of: quizState)` and `.animation(value:)` blind to result-payload changes.
- Fix: either allow `.error → .error` and replace the payload atomically, or make `setError` bail and log when the transition is rejected, so `activeErrorModel` is never written without matching state.

### F. Infra and config drift

**infra-1 — quiz-pack-api's pending/review store sits on ephemeral container disk** · `apps/quiz-pack-api/app/api/routes.py:46` · **verified**
- `QuestionStorage()` at module import in `api/routes.py:46` and `web/routes.py:21`; `generation/storage.py:43` falls back to `SQLitePendingStore()` defaulting to `sqlite:///./data/pending.db` relative to WORKDIR. `apps/quiz-pack-api/fly.toml` has no `[[mounts]]` while `min_machines_running = 0`. Both routers are mounted in prod.
- Impact: much narrower than it looks — nothing in the prod runtime writes here (the pipeline persists to Postgres via `PersistStage`), `generation/storage.py:1-8` documents this class as a legacy remnant fronting only the import/review tooling, all routes are admin-gated, and the real review flow is local (`localhost:8003/web/review`). Residual risk is a latent trap: writes through `/web` on prod vanish on idle-wake with no error.
- Fix: **do not add a Fly volume** (that re-entrenches a store the codebase decided to retire for pgvector, #42/#30). Stop mounting the legacy web/pending routes in prod, or fail fast when `PENDING_DATABASE_URL` is unset with `ENVIRONMENT=production`.

**infra-3 — CI never lints or format-checks quiz-pack-api** · `.github/workflows/backend-ci.yml:118` · **verified**
- `ruff check apps/quiz-agent/ packages/shared/` (:118) and `ruff format --check` on the same two targets (:122), while the path filters (lines 10, 17) do include `apps/quiz-pack-api/**` — so the job runs green on quiz-pack-api-only commits. `.githooks/pre-commit` mirrors the same two targets, so it escapes locally too. Live drift: `ruff@0.15.22 check apps/quiz-pack-api/` → 17 errors; `format --check` → 104 files.
- Impact: lint/format only — quiz-pack-api *is* covered by `test-quiz-pack-api` against Postgres + Redis, and all 17 errors are F401/F541 in `tests/`/`scripts/` (`ruff check app/` is clean). The gap is a two-word workflow edit reading as full coverage.
- Fix: add `apps/quiz-pack-api/` to both ruff invocations (and the hook), landing the format sweep as its own isolated commit.

**infra-4 — both "verify the API contract" CI jobs verify nothing** · `.github/workflows/ios-ci.yml:78` · **verified**
- `verify-api-models` ("Verify API Models Match Backend") exports the OpenAPI spec, asserts only `test -s` (:113), and uploads it — no Swift struct is read, no baseline is committed. Its `on:` filters (8-15) are iOS paths only, so a Pydantic change never triggers it. `backend-ci.yml:194 verify-openapi` is the same shape (though honestly named "Verify OpenAPI Spec Generation").
- Impact: one misleadingly named green check plus a dead path filter. Mitigated in practice by the mandated manual `/verify-api` step, which TODO history shows is actually run. Related open debt: `docs/todo/TODO.md:187` "typed question API contract + /verify-api repair".
- Fix: commit `openapi.json` as a baseline and fail on `diff`, and move the job into `backend-ci.yml` (or add backend paths to the iOS filter).

**infra-6 — `.env.example` documents ~20 of ~49 variables the services read** · `.env.example:1` · **verified**
- Absent: `ELEVENLABS_API_KEY`, `SENTRY_DSN`, `ENVIRONMENT`, `REVENUECAT_*`, `AUTH_JWT_SECRET`, `CORS_ORIGINS`, `AWS_*`, `GENERATION_MODEL`, `JUDGE_MODELS`, `FREE_MONTHLY_LIMIT`, `STOREKIT_ENVIRONMENT`. Self-contradicting case: `.env.example:47` ships `TTS_PROVIDER=elevenlabs` while never naming the key `tts/providers.py:98,103` requires. No alternate inventory exists — none of `docs/setup/*.md` mentions Sentry, RevenueCat or `fly secrets`.
- Impact: real but bounded. Two consequences are overstated: missing ElevenLabs degrades to the OpenAI TTS fallback (`tts/service.py:139-221`), and `STOREKIT_ENVIRONMENT`'s absence is deliberate (`config.py:41-43`: per-deploy Fly secret, never in code). The genuine cost is a one-time provisioning tax on a fresh environment (the Hetzner move), with two `config.py` files as the real source of truth.
- Fix: regenerate from the union of both `Settings` classes plus raw `os.getenv` keys, grouped by service, marked required / optional-degrades / optional-tuning.

**infra-7 — `.env.example` still names Upstash as the production Redis** · `.env.example:71` · *unverified*
- `# Redis (ARQ queue + SSE pubsub). Local = docker-compose. Prod = Upstash (rediss://).` Actual prod is self-hosted (`infra/quiz-pack-redis/fly.toml:1-3`, replaced 2026-07-17), reachable as plain `redis://:<password>@quiz-pack-redis.internal:6379/0` over Fly 6PN. Both the vendor and the TLS scheme are wrong. No live code references Upstash.
- Impact: distinct from infra-6 — this line is not missing but actively wrong, in the one place someone provisioning would look.
- Fix: replace with the self-hosted host + plain `redis://`, pointing at `infra/quiz-pack-redis/README.md`.

**infra-8 — `pytest-asyncio` declared as a runtime dependency** · `apps/quiz-pack-api/pyproject.toml:42` · *unverified*
- It sits in `[project].dependencies`, not the `[project.optional-dependencies].test` extra two lines below whose own comment says "CI installs these explicitly; runtime images do not." Consequently mirrored into `Dockerfile:50`. `respx` is correctly in the extra.
- Impact: the prod image ships a test framework, and the pyproject no longer expresses the runtime/test boundary it documents — the signal the hand-maintained Dockerfile list depends on.
- Fix: move it to the `test` extra and drop it from `Dockerfile:50`; CI installs it explicitly already.

**infra-9 — Redis fails open when `REDIS_PASSWORD` is empty** · `infra/quiz-pack-redis/Dockerfile:6` · *unverified*
- `exec redis-server --requirepass "$REDIS_PASSWORD" --bind 0.0.0.0 :: --protected-mode no ...`. An unset variable expands to `--requirepass ""`, which Redis treats as no password, and the server starts successfully. The rotation runbook (`README.md:27-33`) sets the secret across three apps in sequence — a window where a dropped `-a` leaves it unset.
- Impact: silent fail-open on the queue carrying paid pack orders and SSE progress, open to every app on the Fly org's 6PN. The only symptom is that unauthenticated clients work.
- Fix: guard the CMD — `[ -n "$REDIS_PASSWORD" ] || { echo 'REDIS_PASSWORD unset'; exit 1; }` before `exec`.

### G. Cost and security smalls

**seccost-2 — failed order runs record zero cost** · `apps/quiz-pack-api/app/worker/tasks.py:201` · **verified**
- The `usage_after` snapshot (:183) and the cost writes (201-205) sit strictly after a normal `generator.run` return; the `finally` (178-179) only deactivates the tracker. Both `except` blocks (:215, :233) route to `_handle_failure`, whose transaction (269-301) writes status/error/retry_count/refund_eligible and no cost column. Grep confirms nothing else writes those columns.
- Impact: the runs where money leaves and no revenue arrives are exactly the runs with no cost data — and they are simultaneously `refund_eligible=True`. #143's pack-COGS numbers are a survivorship-biased sample. The same seam under-reports *successful* retried orders, since the snapshot brackets only the final attempt. (Note `stage_cost_cents` is currently 0 everywhere, so the real components are the OpenRouter delta and Tavily credits; reconstruction from OpenRouter account activity is painful, not impossible.)
- Fix: move the `usage_after` snapshot + cost write into a `finally` around `generator.run`, and have `_handle_failure` persist the accumulated costs in its existing transaction.

**seccost-3 — Bedrock spend is invisible to per-order cost tracking, and fails silent** · `apps/quiz-pack-api/app/cost_tracking.py:84` · **verified**
- `fetch_openrouter_usage` gates on the gateway (84-85) and reads OpenRouter's account-wide `total_usage`, but `factory.py:313-314` routes any `bedrock:`-prefixed id straight past the gateway and `resolve_model` exempts them (215-216). With `LLM_GATEWAY=openrouter` and one role pinned to Bedrock, the delta returns a valid number that simply omits the Bedrock calls — violating the docstring's own "returns None whenever the number would be meaningless" contract (78-80). Reachable via `GENERATION_MODEL`/`CRITIQUE_MODEL`/`VERIFY_MODEL`/`ANSWERABILITY_MODEL` pins and via `JUDGE_MODELS` (`multi_model_scorer.py:564`).
- Impact: latent — no `bedrock:` id is pinned today — but the blind-sample winner (Kimi K2.5) is a Bedrock-served model awaiting founder approval, so a mixed stack is one env flip away. Every pack would then persist a confidently wrong `llm_cost_usd` instead of NULL.
- Fix: have the factory report provider usage into the tracker contextvar; either add a Bedrock cost component or return None for `llm_cost_usd` when any Bedrock call occurred.

**seccost-7 — non-ASCII Authorization header 500s the RevenueCat webhook** · `apps/quiz-agent/app/api/routes/webhooks.py:48` · *unverified*
- `provided = request.headers.get("Authorization") or ""` then `hmac.compare_digest(provided, secret)`. Starlette latin-1-decodes header bytes, so any byte ≥ 0x80 makes `compare_digest` raise `TypeError`. The identical bug was already fixed in the sibling admin guard with the reason written out (`admin.py:46-48`, compares as bytes).
- Impact: an unauthenticated caller can turn the money-critical webhook into a 500 generator, and RC retries every non-2xx for days — a self-sustaining retry storm plus fake Sentry noise masking real subscription-delivery failures. Also evidence the earlier fix was applied per-site rather than as a shared helper.
- Fix: compare as bytes, and promote the byte-safe comparison into one shared helper used by both admin guards and the webhook.

**seccost-8 — pack grants dropped when the RC event carries no `transaction_id`** · `apps/quiz-agent/app/usage/rc_service.py:326` · *unverified*
- `_grant_pack` returns after a warning + `capture_message` (308-326) rather than insert, because the dedup is a partial UNIQUE on `store_txn_id` and Postgres treats NULLs as distinct. The comment names the real fix and defers it ("partial unique index on `COALESCE(store_txn_id, rc_event_id)` … needs a migration"). The route still answers `{"status": "ok"}` (webhooks.py:69), so RC never retries.
- Impact: a paid pack purchase can end with no credits, the webhook acknowledged, and only a warning-level breadcrumb. No reconciliation job, no ledger row to repair from. Acceptable while the founder is the only user; a support ticket with no audit trail once that changes.
- Fix: land the deferred migration (partial unique on `COALESCE(store_txn_id, rc_event_id)` where `kind='grant'`), then let the grant insert instead of returning early.

## Proposed approach

Work the sub-sections in order (A → G) as independent commits; nothing here has a cross-cutting dependency, so a partial pass is a valid stopping point.

1. **Triage first, code second.** Every *unverified* item needs its cited line re-read before any edit — the verified subset already had its impact statements corrected during the audit, and several first-pass fix sketches were wrong (backend-5, infra-1, ios-4 are called out inline).
2. **Prefer making the invisible loud over changing behaviour.** The dominant pattern is a detector, counter, or comment with no consequence. For most items (backend-9, backend-10, packapi-3/6/10, seccost-2/3) the correct minimal change is emitting the signal — a split counter, a logger call, a NULL instead of a wrong number — not new control flow.
3. **Two items need a migration** (packapi-9 unique index, seccost-8 partial index). Follow the standing migrate-before-deploy constraint and treat each as its own commit.
4. **Contract items pair a backend and a client edit** (contract-2, contract-4, contract-7). Land the backend side first, then run `/verify-api` before touching Swift.
5. **Two items are policy, not code**: contract-8 (hide COGS behind the admin key now) and infra-1 (stop serving the legacy pending routes in prod rather than provisioning storage for them). Confirm both with the founder before acting — they change what a client can see and what an admin surface can do.
6. **Defer nothing silently.** Anything not fixed in the pass stays as an unchecked box below with a one-line reason.

## Done criteria

- [ ] Every finding above is either fixed, or carries an explicit one-line "not doing, because …" in this file.
- [ ] backend-2: a pytest submits the *final* question id twice against a FINISHED session and gets the replayed verdict, not a 400.
- [ ] backend-4: `update_session` failure is observable (raises or returns a checked result at all 8 call sites); `expires_at` refreshes on write.
- [ ] backend-5: prefetch task is created before an await that actually overlaps it; the misleading comment is gone or accurate.
- [ ] packapi-6: `StageResult.info` distinguishes `verified` / `held_for_review` / `dropped`; a test with a forced Tavily failure asserts `verified == 0`.
- [ ] packapi-3: `advanced_generator.py` has zero `print(...)` on exception paths; a forced parse failure produces a Sentry event carrying `order_id`.
- [ ] packapi-9 / seccost-8: migrations applied to both envs; a duplicate pipeline run for one order fails loud, and a txn-less grant inserts exactly one ledger row across a redelivery.
- [ ] contract-2: `/verify-api` clean, and a delivered pack with `actual_count < target_count` renders the actual number on My Packs.
- [ ] contract-6: `Question.swift` declares no field absent from `PublicQuestionWire` (checked by `/verify-api`).
- [ ] infra-3: `ruff check` and `ruff format --check` cover all three targets and CI is green (format sweep landed as its own commit).
- [ ] infra-9: a container started with `REDIS_PASSWORD` unset exits non-zero instead of serving unauthenticated.
- [ ] seccost-2: a deliberately failed order run persists non-zero `llm_cost_usd` / `search_cost_cents`.
- [ ] seccost-7: a request with a `\x80` byte in `Authorization` returns 401, not 500 (pytest).
- [ ] Backend suites green for both services; deployed to prod; TODO line for #152 updated.
